// Copyright PolyAI Limited

import Foundation
import Combine

/// Lifecycle state of a voice call.
public enum CallState: Sendable, Equatable {
    case idle
    case connecting
    case connected
    case ended
    case failed(PolyError)
}

public extension CallState {
    var isActive: Bool {
        switch self {
        case .connecting, .connected: return true
        default: return false
        }
    }
}

/// A voice call.
///
/// Observable the same way ``ChatSession`` is — `@MainActor` + `ObservableObject`, so
/// SwiftUI can bind straight to ``state`` and ``audioState`` with no manual
/// `for await` plumbing. The ``states`` / ``audioStates`` streams remain for UIKit
/// and other non-SwiftUI consumers.
///
/// The base ``PolyMessaging/voice()`` factory ships **without** a media engine, so its
/// ``start()`` surfaces `PolyError.voice(.notImplemented)`. The **PolyVoice** product supplies
/// a real WebRTC audio engine — call `PolyVoice.call(config:options:)` to place audio calls.
@MainActor
public final class PolyCall: ObservableObject {

    private let coordinator: BridgeCallCoordinator?
    private let config: Configuration?

    private let stateCaster = Multicaster<CallState>(replayLastValue: true)
    private let audioCaster = Multicaster<AudioState>(replayLastValue: true)
    private var relayTask: Task<Void, Never>?
    private var audioRelayTask: Task<Void, Never>?

    /// Current call state.
    @Published public private(set) var state: CallState = .idle

    /// Current audio routing (available outputs + the active one) — drive a device
    /// picker from this. Empty until the call's audio is engaged (``start()``).
    @Published public private(set) var audioState: AudioState = .empty

    /// Call-state transitions, for non-SwiftUI consumers. Late subscribers receive
    /// the current state.
    ///
    /// > Note: each access returns a NEW subscription — read it once and iterate,
    /// > don't call it twice expecting the same stream.
    public nonisolated var states: AsyncStream<CallState> { stateCaster.subscribe() }

    /// Audio-routing snapshots, for non-SwiftUI consumers. Same
    /// one-subscription-per-access caveat as ``states``.
    public nonisolated var audioStates: AsyncStream<AudioState> { audioCaster.subscribe() }

    /// Public (gated) initializer: no media engine is bundled, so this call
    /// cannot carry audio yet. `start()` reports `.voice(.notImplemented)`.
    init(config: Configuration) {
        self.config = config
        self.coordinator = nil
    }

    /// Internal seam: drive a fully-wired pipeline (used by the test suite and
    /// the opt-in live integration probe with an injected media engine).
    init(coordinator: BridgeCallCoordinator) {
        self.config = nil
        self.coordinator = coordinator
        let states = coordinator.stateStream
        let audio = coordinator.audioStream
        relayTask = Task { [weak self] in
            for await newState in states { await self?.setState(newState) }
        }
        audioRelayTask = Task { [weak self] in
            for await newAudio in audio { await self?.setAudioState(newAudio) }
        }
    }

    deinit {
        relayTask?.cancel()
        audioRelayTask?.cancel()
        // Dropping a live call must still release the mic, sockets, and the
        // process-global audio session — the Task retains the coordinator until
        // its teardown completes.
        if let coordinator {
            Task { await coordinator.end() }
        }
    }

    /// Begin the call. Voice calling is not yet available, so for the shipped
    /// SDK this throws `PolyError.voice(.notImplemented)`.
    public func start() async throws {
        guard let coordinator else {
            setState(.failed(.voice(.notImplemented)))
            throw PolyError.voice(.notImplemented)
        }
        try await coordinator.start()
    }

    /// End the call and release its resources. Safe to call at any time, and
    /// returns only once everything (sockets, media engine, audio session) is
    /// actually released — so a new call started right after can't collide
    /// with this one's cleanup.
    public func end() async {
        await coordinator?.end()
        if coordinator == nil { setState(.ended) }
    }

    /// Mute or unmute the local microphone.
    public func setMuted(_ muted: Bool) async {
        await coordinator?.setMuted(muted)
    }

    /// Whether the local microphone is currently muted.
    public var isMuted: Bool {
        get async { await coordinator?.isMuted ?? false }
    }

    /// Route call audio to `device` (an entry from ``audioState``'s `availableDevices`),
    /// or `nil` to revert to automatic routing. Confirmed asynchronously via ``audioState``.
    public func setAudioDevice(_ device: AudioDevice?) async {
        await coordinator?.selectAudioDevice(device)
    }

    private func setState(_ newState: CallState) {
        state = newState
        stateCaster.emit(newState)
    }

    private func setAudioState(_ newAudioState: AudioState) {
        audioState = newAudioState
        audioCaster.emit(newAudioState)
    }
}

public extension PolyCall {

    /// Build a fully-wired voice call driven by the supplied media engine.
    ///
    /// The base SDK ships no media engine, so `PolyMessaging.voice()` reports
    /// `.voice(.notImplemented)`. The **PolyVoice** product calls this with a
    /// WebRTC-backed ``CallMediaEngine`` to place real audio calls — it composes
    /// the same internal REST/session/signaling pipeline the tests exercise.
    ///
    /// - Parameters:
    ///   - config: the shared messaging `Configuration` (connector token, environment, host).
    ///   - webrtcToken: the web calling token (the offer `authToken` + ICE-servers auth).
    ///   - signalingHost: optional `webrtc-bridge` host override (required for `.custom`).
    ///   - mediaEngine: the platform WebRTC engine that produces the SDP offer and carries audio.
    /// - Throws: `PolyError.invalidConfiguration` for a `.custom` environment without a `signalingHost`.
    ///
    /// > Important: SPI, not API. This hard-codes the SDK's entire internal composition
    /// > (`RestApi`, `VoiceSessionLinker`, `BridgeApi`, `WebSocketEventsChannel`,
    /// > `BridgeCallCoordinator`) in its signature. As public API that shape could never
    /// > change without a major bump; as SPI it stays ours to refactor.
    @_spi(PolyVoice)
    static func wired(
        config: Configuration,
        webrtcToken: String,
        signalingHost: String? = nil,
        mediaEngine: CallMediaEngine
    ) throws -> PolyCall {
        let logger = OSLogLogger(level: config.logLevel)
        let urls = EnvironmentURLs(environment: config.environment)
        let hostId = config.hostIdentifier ?? Bundle.main.bundleIdentifier ?? ""
        let api = RestApi(
            baseURL: urls.restBaseURL,
            apiKey: config.apiKey,
            hostIdentifier: hostId,
            logger: logger
        )
        let linker = VoiceSessionLinker(
            connection: WebSocketTransport(logger: logger),
            wsBaseURL: urls.wsBaseURL,
            logger: logger
        )
        let bridgeEnv = try BridgeEnvironment(environment: config.environment, bridgeHost: signalingHost)
        let bridge = BridgeApi(
            baseURL: bridgeEnv.baseURL,
            authToken: webrtcToken,
            logger: logger
        )
        let coordinator = BridgeCallCoordinator(
            api: api,
            bridge: bridge,
            linker: linker,
            media: mediaEngine,
            makeEventsChannel: { url in WebSocketEventsChannel(url: url, logger: logger) },
            streamingEnabled: config.streamingEnabled,
            logger: logger
        )
        return PolyCall(coordinator: coordinator)
    }
}
