// Copyright PolyAI Limited

import UIKit
import PolyMessaging
import PolyVoice

/// 01-Hello's tap-to-call, now as a **system call** via CallKit: green call
/// indicator, lock-screen / AirPods / car controls, and hold arbitration when a
/// cellular call arrives. All user intents route through `CallKitController`;
/// the `PolyCall` only ever reacts to the provider's `perform` callbacks.
/// The UIKit counterpart of the SwiftUI 02-CallKit example.
///
/// CallKit is broken on the simulator (calls are auto-ended, `didActivate`
/// never fires), so there the example falls back to a plain 01-Hello-style call.
final class CallViewController: UIViewController {

    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let callButton = UIButton(type: .system)
    private let muteButton = UIButton(type: .system)
    private let outputLabel = UILabel()
    private let speakerButton = UIButton(type: .system)
    private let hintLabel = UILabel()

    private let callKit = CallKitController()
    private var call: PolyCall?
    private var observer: Task<Void, Never>?
    private var audioObserver: Task<Void, Never>?
    private var muted = false
    private var state: CallState = .idle { didSet { render() } }
    private var audioState: AudioState = .empty { didSet { renderAudio() } }

    #if targetEnvironment(simulator)
    private let callKitAvailable = false
    #else
    private let callKitAvailable = true
    #endif

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        titleLabel.text = "PolyAI Voice + CallKit"
        titleLabel.font = .systemFont(ofSize: 34, weight: .bold)
        titleLabel.textAlignment = .center
        titleLabel.adjustsFontSizeToFitWidth = true

        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.textColor = .secondaryLabel

        callButton.setTitle("Start call", for: .normal)
        callButton.titleLabel?.font = .systemFont(ofSize: 20, weight: .semibold)
        callButton.addTarget(self, action: #selector(toggleCall), for: .touchUpInside)

        muteButton.setTitle("Mute", for: .normal)
        muteButton.addTarget(self, action: #selector(toggleMute), for: .touchUpInside)
        muteButton.isHidden = true

        outputLabel.textAlignment = .center
        outputLabel.font = .systemFont(ofSize: 13)
        outputLabel.textColor = .secondaryLabel
        outputLabel.isHidden = true

        speakerButton.addTarget(self, action: #selector(toggleSpeaker), for: .touchUpInside)
        speakerButton.isHidden = true

        hintLabel.text = "Lock the screen or background the app —\nthe call survives, and the system UI controls it."
        hintLabel.font = .systemFont(ofSize: 13)
        hintLabel.textColor = .secondaryLabel
        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 0
        hintLabel.isHidden = true

        let stack = UIStackView(arrangedSubviews: [titleLabel, statusLabel, callButton, muteButton, outputLabel, speakerButton, hintLabel])
        stack.axis = .vertical
        stack.spacing = 20
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
        ])
        render()
    }

    // MARK: - Actions (user intents go to CallKit; the call obeys `perform`)

    @objc private func toggleCall() {
        if state.isActive {
            if callKitAvailable { callKit.requestEnd() } else { Task { await call?.end() } }
        } else {
            startCall()
        }
    }

    @objc private func toggleMute() {
        if callKitAvailable {
            callKit.requestMute(!muted) // state updates when CallKit performs it
        } else {
            setMuted(!muted)
        }
    }

    private func setMuted(_ newValue: Bool) {
        muted = newValue
        muteButton.setTitle(muted ? "Unmute" : "Mute", for: .normal)
        Task { await call?.setMuted(newValue) }
    }

    private func startCall() {
        let newCall: PolyCall
        do {
            // No config to pass — PolyVoice.call() reads what AppDelegate set.
            newCall = try PolyVoice.call(
                options: VoiceOptions(callKit: callKitAvailable) // audio start/stop deferred to CallKit
            )
        } catch {
            state = .failed(error as? PolyError ?? .voice(.signalingFailed("\(error)")))
            return
        }
        muted = false
        muteButton.setTitle("Mute", for: .normal)
        call = newCall
        observeCall(newCall)

        // The system approves the call, then `perform(CXStartCallAction)` runs
        // `performStart` below. Without CallKit (simulator), start directly.
        callKit.performStart = { Task { try? await newCall.start() } }
        callKit.performEnd = { Task { await newCall.end() } }
        callKit.performMute = { [weak self] m in
            Task { @MainActor in self?.setMuted(m) }
        }
        callKit.onRequestError = { [weak self] error in
            Task { @MainActor in
                self?.state = .failed(.voice(.signalingFailed("CallKit refused the call: \(error.localizedDescription)")))
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
    private func observeCall(_ newCall: PolyCall) {
        observer?.cancel()
        audioObserver?.cancel()
        let states = newCall.states
        observer = Task { [weak self] in
            for await newState in states {
                await MainActor.run {
                    guard let self else { return }
                    self.state = newState
                    guard self.callKitAvailable else { return }
                    switch newState {
                    case .connected: self.callKit.reportConnected()
                    case .ended: self.callKit.reportEnded(failed: false)
                    case .failed: self.callKit.reportEnded(failed: true)
                    default: break
                    }
                }
            }
        }
        let audioStates = newCall.audioStates
        audioObserver = Task { [weak self] in
            for await snapshot in audioStates {
                await MainActor.run { self?.audioState = snapshot }
            }
        }
    }

    // iOS keeps one active output + auto-routes accessories; speaker ↔ earpiece is the one
    // output an app reliably controls. Works under CallKit too.
    @objc private func toggleSpeaker() {
        let isSpeaker = audioState.selectedDevice?.kind == .speakerphone
        let target: AudioDevice.Kind = isSpeaker ? .earpiece : .speakerphone
        if let device = audioState.availableDevices.first(where: { $0.kind == target }) {
            Task { await call?.setAudioDevice(device) }
        }
    }

    private func renderAudio() {
        let hasAudio = !audioState.availableDevices.isEmpty
        outputLabel.isHidden = !hasAudio
        speakerButton.isHidden = !hasAudio
        outputLabel.text = audioState.selectedDevice.map { "Output: \($0.name)" }
        let isSpeaker = audioState.selectedDevice?.kind == .speakerphone
        speakerButton.setTitle(isSpeaker ? "Speaker: on" : "Speaker: off", for: .normal)
    }

    private func render() {
        switch state {
        case .idle: statusLabel.text = "Tap to call the agent"
        case .connecting: statusLabel.text = "Connecting…"
        case .connected: statusLabel.text = "Connected — say hello 👋"
        case .ended: statusLabel.text = "Call ended"
        case .failed(let error): statusLabel.text = "Failed: \(error)"
        }
        switch state {
        case .connecting: callButton.setTitle("Connecting…", for: .normal)
        case .connected: callButton.setTitle("End call", for: .normal)
        default: callButton.setTitle("Start call", for: .normal)
        }
        callButton.isEnabled = { if case .connecting = state { return false }; return true }()
        let connected: Bool = { if case .connected = state { return true }; return false }()
        muteButton.isHidden = !connected
        hintLabel.isHidden = !connected
    }
}
