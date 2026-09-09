// Copyright PolyAI Limited

import SwiftUI
import PolyMessaging
import PolyVoice

struct ContentView: View {
    @State private var call: PolyCall?
    /// Only used before the first call exists (and to surface a construction failure) —
    /// once there's a `PolyCall`, `CallPanel` observes it directly.
    @State private var setupFailure: PolyError?

    var body: some View {
        VStack(spacing: 24) {
            Text("PolyAI Voice").font(.largeTitle.bold())

            if let call {
                // `PolyCall` is an ObservableObject, so the panel re-renders itself
                // on every state / audio-route change — no `for await` plumbing.
                CallPanel(call: call, onRestart: startCall)
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

    private func startCall() {
        do {
            // No config/options to pass — PolyVoice.call() reads what VoiceApp.swift set.
            let newCall = try PolyVoice.call()
            setupFailure = nil
            call = newCall
            Task { try? await newCall.start() }
        } catch {
            setupFailure = error as? PolyError ?? .voice(.signalingFailed("\(error)"))
        }
    }
}

/// The live-call UI. Binding to `PolyCall` directly is the whole point: `state`
/// and `audioState` are `@Published`, so this view stays in sync on its own.
private struct CallPanel: View {
    @ObservedObject var call: PolyCall
    let onRestart: () -> Void

    @State private var muted = false

    var body: some View {
        VStack(spacing: 24) {
            Text(statusText)
                .foregroundStyle(statusColor)
                .multilineTextAlignment(.center)

            Button(action: toggleCall) {
                Text(buttonText).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(call.state.isActive ? .red : .accentColor)
            .disabled(isConnecting)

            if isConnected {
                Button(muted ? "Unmute" : "Mute") { toggleMute() }
                    .buttonStyle(.bordered)

                // iOS keeps one active output + auto-routes accessories; the app's real
                // control is speaker ↔ earpiece. Show the current route, toggle the speaker.
                if let selected = call.audioState.selectedDevice {
                    Text("Output: \(selected.name)").font(.caption).foregroundStyle(.secondary)
                    Button(isSpeaker ? "Speaker: on" : "Speaker: off") { toggleSpeaker() }
                        .buttonStyle(.bordered)
                }
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

    // MARK: - Actions

    private func toggleCall() {
        if call.state.isActive {
            Task { await call.end() }
        } else {
            onRestart()
        }
    }

    private func toggleMute() {
        muted.toggle()
        Task { await call.setMuted(muted) }
    }

    /// Flip between the loudspeaker and the earpiece. Accessories (headset/Bluetooth) are
    /// routed by the system automatically; this is the one output an app reliably controls.
    private func toggleSpeaker() {
        let target: AudioDevice.Kind = isSpeaker ? .earpiece : .speakerphone
        if let device = call.audioState.availableDevices.first(where: { $0.kind == target }) {
            Task { await call.setAudioDevice(device) }
        }
    }
}
