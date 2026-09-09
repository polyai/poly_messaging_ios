// Copyright PolyAI Limited

import SwiftUI
import PolyMessaging
import PolyVoice

/// 01-Hello's tap-to-call, now as a **system call**: CallKit shows the green
/// call indicator, lock-screen / AirPods / car controls work, and a cellular
/// call offers hold instead of killing the agent call. All user intents route
/// through `CallKitController`; the `PolyCall` only ever reacts to the
/// provider's `perform` callbacks.
///
/// CallKit is broken on the simulator (calls are auto-ended, `didActivate`
/// never fires), so there the example falls back to a plain 01-Hello-style call.
struct ContentView: View {
    @State private var call: PolyCall?
    @State private var setupFailure: PolyError?
    @State private var muted = false
    @State private var callKit = CallKitController()
    /// Mirrors call state INTO CallKit (a side effect, not UI) — the UI itself
    /// binds to `PolyCall` directly via `@ObservedObject`.
    @State private var reporter: Task<Void, Never>?

    #if targetEnvironment(simulator)
    private let callKitAvailable = false
    #else
    private let callKitAvailable = true
    #endif

    var body: some View {
        VStack(spacing: 24) {
            Text("PolyAI Voice + CallKit").font(.largeTitle.bold())

            if let call {
                CallPanel(
                    call: call,
                    muted: muted,
                    onToggleCall: { toggleCall(call) },
                    onToggleMute: { toggleMute(call) }
                )
            } else {
                Text(setupFailure.map { "Failed: \($0)" } ?? "Tap to call the agent")
                    .foregroundStyle(setupFailure == nil ? Color.secondary : Color.red)
                    .multilineTextAlignment(.center)
                Button(action: startCall) {
                    Text("Start call").frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
    }

    // MARK: - Actions (user intents go to CallKit; the call obeys `perform`)

    private func toggleCall(_ call: PolyCall) {
        if call.state.isActive {
            if callKitAvailable { callKit.requestEnd() } else { Task { await call.end() } }
        } else {
            startCall()
        }
    }

    private func toggleMute(_ call: PolyCall) {
        if callKitAvailable {
            callKit.requestMute(!muted) // state updates when CallKit performs it
        } else {
            muted.toggle()
            Task { await call.setMuted(muted) }
        }
    }

    private func startCall() {
        let newCall: PolyCall
        do {
            // No config to pass — PolyVoice.call() reads what VoiceApp.swift set.
            newCall = try PolyVoice.call(
                options: VoiceOptions(callKit: callKitAvailable) // audio start/stop deferred to CallKit
            )
        } catch {
            setupFailure = error as? PolyError ?? .voice(.signalingFailed("\(error)"))
            return
        }
        setupFailure = nil
        muted = false
        call = newCall
        reportStateToCallKit(newCall)

        // The system approves the call, then `perform(CXStartCallAction)` runs
        // `performStart` below. Without CallKit (simulator), start directly.
        callKit.performStart = { Task { try? await newCall.start() } }
        callKit.performEnd = { Task { await newCall.end() } }
        callKit.performMute = { m in
            Task { await newCall.setMuted(m) }
            muted = m
        }
        callKit.onRequestError = { error in
            Task { @MainActor in
                setupFailure = .voice(.signalingFailed("CallKit refused the call: \(error.localizedDescription)"))
                call = nil
            }
        }
        if callKitAvailable {
            callKit.requestStart(agentName: "PolyAI Agent")
        } else {
            Task { try? await newCall.start() }
        }
    }

    /// Mirror the call's real state into CallKit: connected → the system call
    /// timer starts; agent hangup / failure → reported (a user hangup was
    /// already a `CXEndCallAction`, so `reportEnded` no-ops by then).
    ///
    /// This consumes ``PolyCall/states`` rather than the `@Published` `state`
    /// because it's a side effect that must see EVERY transition, not just the
    /// latest value a view happens to render.
    private func reportStateToCallKit(_ newCall: PolyCall) {
        guard callKitAvailable else { return }
        reporter?.cancel()
        let states = newCall.states
        reporter = Task {
            for await newState in states {
                await MainActor.run {
                    switch newState {
                    case .connected: callKit.reportConnected()
                    case .ended: callKit.reportEnded(failed: false)
                    case .failed: callKit.reportEnded(failed: true)
                    default: break
                    }
                }
            }
        }
    }
}

/// The live-call UI, bound straight to `PolyCall`'s `@Published` state.
private struct CallPanel: View {
    @ObservedObject var call: PolyCall
    let muted: Bool
    let onToggleCall: () -> Void
    let onToggleMute: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Text(statusText)
                .foregroundStyle(statusColor)
                .multilineTextAlignment(.center)

            Button(action: onToggleCall) {
                Text(buttonText).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(call.state.isActive ? .red : .accentColor)
            .disabled(isConnecting)

            if isConnected {
                Button(muted ? "Unmute" : "Mute", action: onToggleMute)
                    .buttonStyle(.bordered)

                if let selected = call.audioState.selectedDevice {
                    Text("Output: \(selected.name)").font(.caption).foregroundStyle(.secondary)
                    Button(isSpeaker ? "Speaker: on" : "Speaker: off") { toggleSpeaker() }
                        .buttonStyle(.bordered)
                }

                Text("Lock the screen or background the app —\nthe call survives, and the system UI controls it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: - Derived UI

    private var isConnecting: Bool { if case .connecting = call.state { return true }; return false }
    private var isConnected: Bool { if case .connected = call.state { return true }; return false }
    private var isSpeaker: Bool { call.audioState.selectedDevice?.kind == .speakerphone }

    private var statusText: String {
        switch call.state {
        case .idle: return "Tap to call the agent"
        case .connecting: return "Connecting…"
        case .connected: return "Connected — say hello 👋"
        case .ended: return "Call ended"
        case .failed(let error): return "Failed: \(error)"
        }
    }

    private var statusColor: Color {
        switch call.state {
        case .connected: return .green
        case .failed: return .red
        case .connecting: return .orange
        default: return .secondary
        }
    }

    private var buttonText: String {
        switch call.state {
        case .connecting: return "Connecting…"
        case .connected: return "End call"
        default: return "Start another call"
        }
    }

    /// Flip between the loudspeaker and the earpiece. Accessories (headset/Bluetooth)
    /// are routed by the system automatically; this works under CallKit too.
    private func toggleSpeaker() {
        let target: AudioDevice.Kind = isSpeaker ? .earpiece : .speakerphone
        if let device = call.audioState.availableDevices.first(where: { $0.kind == target }) {
            Task { await call.setAudioDevice(device) }
        }
    }
}
