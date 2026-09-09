// Copyright PolyAI Limited

import Foundation
@_spi(PolyVoice) import PolyMessaging
#if os(iOS)
import AVFAudio
import WebRTC
#endif

/// Entry point for WebRTC voice calling — the PolyVoice companion to PolyMessaging.
///
/// Ships as a **separate** product so chat-only apps never link the WebRTC binary.
/// It reuses the messaging
/// `Configuration` and the same `CallState` / `PolyError` vocabulary.
///
/// ```swift
/// // At launch — sets both tokens once (webrtcToken is only needed for voice):
/// PolyMessaging.initialize(.init(apiKey: "…", webrtcToken: "…"))
///
/// // Elsewhere — no config to pass, same pattern as PolyMessaging.chat():
/// let call = try PolyVoice.call()
/// for await state in call.states { /* .connecting → .connected → … */ }
/// try await call.start()   // after the microphone permission is granted
/// ```
///
/// Need a different connector than the one `initialize(_:)` set? Pass a `Configuration`
/// explicitly instead: `call(config:options:)`.
public enum PolyVoice {

    #if os(iOS)
    /// Build a `PolyCall` backed by the real WebRTC audio engine. Does not start
    /// it — observe `PolyCall.states` and call `PolyCall.start()`.
    ///
    /// - Parameters:
    ///   - config: the shared messaging `Configuration` (connector token, environment, host —
    ///     and optionally `webrtcToken`, see below).
    ///   - options: voice options. A web calling token is required, from either
    ///     `options.webrtcToken` or, when that's `nil`, `config.webrtcToken` — the former wins
    ///     when both are set. Defaults to `VoiceOptions()`, so `call(config:)` alone works when
    ///     `config.webrtcToken` is already set.
    /// - Throws: `PolyError.invalidConfiguration` if `apiKey` is empty, if neither
    ///   `options.webrtcToken` nor `config.webrtcToken` is set, or the environment is `.custom`
    ///   without `VoiceOptions.signalingHost`.
    /// > Note: `@MainActor`, matching ``PolyMessaging/voice()`` and
    /// > ``PolyMessaging/chat()`` — ``PolyCall`` is an `ObservableObject`, so it
    /// > is created and observed on the main actor like `ChatSession`.
    @MainActor
    public static func call(config: Configuration, options: VoiceOptions = VoiceOptions()) throws -> PolyCall {
        guard !config.apiKey.isEmpty else {
            throw PolyError.invalidConfiguration("Configuration.apiKey must not be empty")
        }
        guard let webrtcToken = options.webrtcToken ?? config.webrtcToken, !webrtcToken.isEmpty else {
            throw PolyError.invalidConfiguration(
                "A web calling token is required — set VoiceOptions.webrtcToken or Configuration.webrtcToken"
            )
        }
        let audio = AudioSessionController(
            defaultToSpeaker: options.speakerphone,
            callKitMode: options.callKit
        )
        let engine = WebRTCCallMediaEngine(audio: audio)
        return try PolyCall.wired(
            config: config,
            webrtcToken: webrtcToken,
            signalingHost: options.signalingHost,
            mediaEngine: engine
        )
    }

    /// Same as ``call(config:options:)``, but reads the `Configuration` from
    /// `PolyMessaging.initialize(_:)` instead of taking one — the ``PolyMessaging/chat()``
    /// / ``PolyMessaging/voice()`` pattern. Requires `initialize(_:)` to have been called
    /// first (crashes otherwise, same contract as those two); requires `Configuration.webrtcToken`
    /// to have been set there too, unless `options.webrtcToken` supplies one.
    @MainActor
    public static func call(options: VoiceOptions = VoiceOptions()) throws -> PolyCall {
        try call(config: PolyMessaging.currentConfig, options: options)
    }

    // MARK: - CallKit audio-session hooks (pair with `VoiceOptions.callKit`)
    //
    // CallKit's contract: the app configures the audio session early but NEVER
    // activates it — the system does, at phone-call priority, and reports it via
    // `CXProviderDelegate`. These three statics are the exact forwarding the
    // delegate must do. They act on WebRTC's process-global audio session, which
    // is why they live on `PolyVoice`, not on an individual call.

    /// Call from `provider(_:perform action: CXStartCallAction)` **before**
    /// fulfilling the action: applies the voice-call session shape
    /// (playAndRecord / voiceChat / Bluetooth) so the session CallKit is about
    /// to activate is already configured. Never activates.
    public static func callKitConfigureAudioSession() {
        let session = RTCAudioSession.sharedInstance()
        session.useManualAudio = true
        session.isAudioEnabled = false
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        try? session.setConfiguration(AudioSessionController.callConfiguration())
    }

    /// Call from `provider(_:didActivate audioSession:)`: hands the system-activated
    /// session to WebRTC, then releases the audio unit. **Order matters** — the
    /// activation notification first (it clears any stale interruption latch),
    /// the enable second (it's ignored while WebRTC believes it's interrupted).
    public static func callKitAudioSessionDidActivate(_ audioSession: AVAudioSession) {
        let session = RTCAudioSession.sharedInstance()
        session.audioSessionDidActivate(audioSession)
        session.isAudioEnabled = true
    }

    /// Call from `provider(_:didDeactivate audioSession:)`: stops the audio unit
    /// and tells WebRTC the session is gone.
    public static func callKitAudioSessionDidDeactivate(_ audioSession: AVAudioSession) {
        let session = RTCAudioSession.sharedInstance()
        session.audioSessionDidDeactivate(audioSession)
        session.isAudioEnabled = false
    }
    #endif
}
