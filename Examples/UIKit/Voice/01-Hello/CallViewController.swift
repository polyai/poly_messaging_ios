// Copyright PolyAI Limited

import UIKit
import PolyMessaging
import PolyVoice

/// The smallest voice call in UIKit: PolyVoice.call(...), observe state, start/end.
/// The UIKit counterpart of the SwiftUI Voice example.
final class CallViewController: UIViewController {

    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let callButton = UIButton(type: .system)
    private let muteButton = UIButton(type: .system)
    private let outputLabel = UILabel()
    private let speakerButton = UIButton(type: .system)

    private var call: PolyCall?
    private var observer: Task<Void, Never>?
    private var audioObserver: Task<Void, Never>?
    private var muted = false
    private var state: CallState = .idle { didSet { render() } }
    private var audioState: AudioState = .empty { didSet { renderAudio() } }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        titleLabel.text = "PolyAI Voice"
        titleLabel.font = .systemFont(ofSize: 34, weight: .bold)
        titleLabel.textAlignment = .center

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

        let stack = UIStackView(arrangedSubviews: [titleLabel, statusLabel, callButton, muteButton, outputLabel, speakerButton])
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

    @objc private func toggleCall() {
        if state.isActive {
            Task { await call?.end() }
        } else {
            startCall()
        }
    }

    private func startCall() {
        let newCall: PolyCall
        do {
            // No config/options to pass — PolyVoice.call() reads what AppDelegate set.
            newCall = try PolyVoice.call()
        } catch {
            state = .failed(error as? PolyError ?? .voice(.signalingFailed("\(error)")))
            return
        }
        muted = false
        call = newCall

        observer?.cancel()
        audioObserver?.cancel()
        let states = newCall.states
        observer = Task { [weak self] in
            for await newState in states {
                await MainActor.run { self?.state = newState }
            }
        }
        let audioStates = newCall.audioStates
        audioObserver = Task { [weak self] in
            for await snapshot in audioStates {
                await MainActor.run { self?.audioState = snapshot }
            }
        }
        Task { try? await newCall.start() }
    }

    @objc private func toggleMute() {
        muted.toggle()
        muteButton.setTitle(muted ? "Unmute" : "Mute", for: .normal)
        Task { await call?.setMuted(muted) }
    }

    // iOS keeps one active output + auto-routes accessories; speaker ↔ earpiece is the one
    // output an app reliably controls.
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
        muteButton.isHidden = { if case .connected = state { return false }; return true }()
    }
}
