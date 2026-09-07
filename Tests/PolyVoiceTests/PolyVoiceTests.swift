// Copyright PolyAI Limited

import XCTest
@_spi(PolyVoice) import PolyMessaging
@testable import PolyVoice

/// Tests for the PolyVoice product surface. The WebRTC-backed implementation is
/// iOS-only, so the meat of this suite is `#if os(iOS)` and exercised by the
/// iOS-simulator CI leg (`xcodebuild test`); under `swift test` on macOS it
/// compiles to the options-only subset.
///
/// `@MainActor` because `PolyVoice.call(...)` and `PolyCall` are — `PolyCall` is
/// an `ObservableObject` created and observed on the main actor, like `ChatSession`.
@MainActor
final class PolyVoiceTests: XCTestCase {

    func test_voiceOptions_defaults() {
        let options = VoiceOptions(webrtcToken: "t")
        XCTAssertEqual(options.webrtcToken, "t")
        XCTAssertTrue(options.speakerphone, "hands-free is the default for a voice agent")
        XCTAssertNil(options.signalingHost)
        XCTAssertFalse(options.callKit, "CallKit integration is strictly opt-in")
        XCTAssertEqual(options.transport, .gateway, "the shipped path stays the default")
    }

    func test_voiceOptions_bridgeTransportIsOptIn() {
        let options = VoiceOptions(webrtcToken: "t", transport: .bridge)
        XCTAssertEqual(options.transport, .bridge)
    }

    #if os(iOS)
    func test_call_emptyApiKey_throws() {
        XCTAssertThrowsError(try PolyVoice.call(
            config: Configuration(apiKey: ""),
            options: VoiceOptions(webrtcToken: "t")
        )) { error in
            guard case PolyError.invalidConfiguration = error else {
                return XCTFail("expected invalidConfiguration, got \(error)")
            }
        }
    }

    func test_call_emptyWebrtcToken_throws() {
        XCTAssertThrowsError(try PolyVoice.call(
            config: Configuration(apiKey: "k"),
            options: VoiceOptions(webrtcToken: "")
        ))
    }

    func test_call_customEnvironmentWithoutSignalingHost_throws() {
        let custom = Configuration(
            apiKey: "k",
            environment: .custom(
                restBaseURL: URL(string: "https://gw.example/api/v1")!,
                wsBaseURL: URL(string: "wss://gw.example/ws")!
            )
        )
        XCTAssertThrowsError(try PolyVoice.call(config: custom, options: VoiceOptions(webrtcToken: "t")))
    }

    func test_call_buildsIdleCall_withRealEngine() throws {
        // Wires the REAL WebRTC media engine + audio controller (construction only —
        // nothing touches the peer factory or audio session until start()).
        let call = try PolyVoice.call(
            config: Configuration(apiKey: "k"),
            options: VoiceOptions(webrtcToken: "t")
        )
        XCTAssertEqual(call.state, .idle)
        XCTAssertFalse(call.state.isActive)
    }

    func test_call_bridgeTransport_buildsIdleCall_withRealEngine() throws {
        // Same real engine, wired to the bridge pipeline instead of the gateway one.
        let call = try PolyVoice.call(
            config: Configuration(apiKey: "k"),
            options: VoiceOptions(webrtcToken: "t", transport: .bridge)
        )
        XCTAssertEqual(call.state, .idle)
    }

    func test_call_bridgeTransport_customEnvironmentWithoutHost_throws() {
        let custom = Configuration(
            apiKey: "k",
            environment: .custom(
                restBaseURL: URL(string: "https://gw.example/api/v1")!,
                wsBaseURL: URL(string: "wss://gw.example/ws")!
            )
        )
        XCTAssertThrowsError(
            try PolyVoice.call(config: custom, options: VoiceOptions(webrtcToken: "t", transport: .bridge))
        )
    }

    func test_call_callKitMode_buildsIdleCall() throws {
        let call = try PolyVoice.call(
            config: Configuration(apiKey: "k"),
            options: VoiceOptions(webrtcToken: "t", callKit: true)
        )
        XCTAssertEqual(call.state, .idle)
    }
    #endif
}

// MARK: - CallKit audio seam (iOS-only; exercised by the simulator CI leg)

#if os(iOS)
import WebRTC

/// Tests the manual-audio contract behind `VoiceOptions.callKit` against the real
/// process-global `RTCAudioSession`. Serialized within the class because the
/// session IS global state.
final class CallKitAudioSeamTests: XCTestCase {

    override func tearDown() {
        // Leave the global session the way non-CallKit code expects it.
        let session = RTCAudioSession.sharedInstance()
        session.isAudioEnabled = false
        session.useManualAudio = false
        super.tearDown()
    }

    func test_configureAudioSession_armsManualAudio_withoutEnabling() {
        PolyVoice.callKitConfigureAudioSession()
        let session = RTCAudioSession.sharedInstance()
        XCTAssertTrue(session.useManualAudio, "CallKit mode must stop WebRTC auto-starting the audio unit")
        XCTAssertFalse(session.isAudioEnabled, "audio stays gated until the system activates the session")
    }

    func test_activateHook_enablesAudio_deactivateHook_disablesIt() {
        PolyVoice.callKitConfigureAudioSession()
        let session = RTCAudioSession.sharedInstance()

        PolyVoice.callKitAudioSessionDidActivate(AVAudioSession.sharedInstance())
        XCTAssertTrue(session.isAudioEnabled, "didActivate releases the audio unit")

        PolyVoice.callKitAudioSessionDidDeactivate(AVAudioSession.sharedInstance())
        XCTAssertFalse(session.isAudioEnabled, "didDeactivate stops the audio unit")
    }

    func test_createOffer_callKitMode_armsManualAudio_andStillProducesSDP() async throws {
        let audio = AudioSessionController(defaultToSpeaker: true, callKitMode: true)
        let engine = WebRTCCallMediaEngine(audio: audio)
        let sdp = try await engine.createOffer(iceServers: [])
        XCTAssertTrue(sdp.contains("m=audio"), "a real audio offer is produced")
        XCTAssertTrue(RTCAudioSession.sharedInstance().useManualAudio,
                      "the engine arms manual audio before the first track exists")
        await engine.close()
    }

    func test_createOffer_callKitMode_neverStompsAnEarlierActivation() async throws {
        // Signaling takes seconds, so CallKit usually activates (didActivate →
        // isAudioEnabled = true) BEFORE createOffer runs. The engine must not
        // re-gate audio off — that was the "connected but silent call" bug.
        PolyVoice.callKitConfigureAudioSession()
        RTCAudioSession.sharedInstance().isAudioEnabled = true // didActivate already came

        let audio = AudioSessionController(defaultToSpeaker: true, callKitMode: true)
        let engine = WebRTCCallMediaEngine(audio: audio)
        _ = try await engine.createOffer(iceServers: [])
        XCTAssertTrue(RTCAudioSession.sharedInstance().isAudioEnabled,
                      "createOffer must leave the CallKit audio gate alone")
        await engine.close()
    }

    func test_createOffer_defaultMode_resetsManualAudio() async throws {
        // A leftover manual flag from a previous CallKit call must not silence
        // a subsequent plain call.
        RTCAudioSession.sharedInstance().useManualAudio = true

        let audio = AudioSessionController(defaultToSpeaker: true, callKitMode: false)
        let engine = WebRTCCallMediaEngine(audio: audio)
        _ = try await engine.createOffer(iceServers: [])
        XCTAssertFalse(RTCAudioSession.sharedInstance().useManualAudio,
                       "a non-CallKit call resets the process-global manual-audio flag")
        await engine.close()
    }
}
#endif

// MARK: - Bridge capabilities on the real engine (iOS-only)

#if os(iOS)
/// Exercises the four capabilities the `webrtc-bridge` path adds, against the real
/// WebRTC engine on a simulator: the non-trickle gather wait, the gathered local
/// description, the mic transceiver's mid, and remote-track control.
final class WebRTCBridgeCapabilityTests: XCTestCase {

    /// The heart of the non-trickle change: after the wait, the local description
    /// must already carry candidates, because the bridge's SDP proxy has no
    /// candidate channel to trickle them down later.
    func test_awaitIceGathering_thenLocalDescriptionCarriesCandidates() async throws {
        let engine = WebRTCCallMediaEngine(
            audio: AudioSessionController(defaultToSpeaker: true, callKitMode: false)
        )
        defer { Task { await engine.close() } }

        _ = try await engine.createOffer(iceServers: IceServer.bridgeDefaultServers)
        await engine.awaitIceGathering(quiet: 0.2, cap: 2.0)

        let gathered = await engine.localDescriptionSDP()
        let sdp = try XCTUnwrap(gathered)
        XCTAssertTrue(sdp.contains("m=audio"))
        XCTAssertTrue(sdp.contains("a=candidate"), "the offer POSTed to the bridge must carry its candidates")
    }

    /// The mid tells the SFU which m-line carries the published mic track.
    func test_audioMid_identifiesTheMicrophoneTransceiver() async throws {
        let engine = WebRTCCallMediaEngine(
            audio: AudioSessionController(defaultToSpeaker: true, callKitMode: false)
        )
        defer { Task { await engine.close() } }

        _ = try await engine.createOffer(iceServers: [])
        let mid = await engine.audioMid()
        XCTAssertEqual(mid, "0", "the single audio m-line is mid 0")
    }

    /// Barge-in can fire before a re-pull has delivered a track; that must be a
    /// no-op rather than a crash, and the intent is applied when the track lands.
    func test_setRemoteAudioEnabled_isSafeBeforeAnyRemoteTrack() async throws {
        let engine = WebRTCCallMediaEngine(
            audio: AudioSessionController(defaultToSpeaker: true, callKitMode: false)
        )
        defer { Task { await engine.close() } }

        _ = try await engine.createOffer(iceServers: [])
        await engine.setRemoteAudioEnabled(false)
        await engine.setRemoteAudioEnabled(true)
    }

    /// A renegotiation offer that isn't valid SDP must surface as a media failure,
    /// not leave the peer in a half-applied state.
    func test_acceptRemoteOffer_rejectsInvalidSdp() async throws {
        let engine = WebRTCCallMediaEngine(
            audio: AudioSessionController(defaultToSpeaker: true, callKitMode: false)
        )
        defer { Task { await engine.close() } }

        _ = try await engine.createOffer(iceServers: [])
        do {
            _ = try await engine.acceptRemoteOffer(sdp: "not-an-sdp")
            XCTFail("expected the invalid renegotiation offer to throw")
        } catch {
            // Any error is acceptable; the point is that it does not succeed.
        }
    }

    func test_acceptRemoteOffer_withNoPeer_throwsMediaFailed() async {
        let engine = WebRTCCallMediaEngine(
            audio: AudioSessionController(defaultToSpeaker: true, callKitMode: false)
        )
        do {
            _ = try await engine.acceptRemoteOffer(sdp: "v=0")
            XCTFail("expected a media failure without a peer connection")
        } catch {
            guard case PolyError.voice(.mediaFailed) = error else {
                return XCTFail("expected .mediaFailed, got \(error)")
            }
        }
    }
}
#endif
