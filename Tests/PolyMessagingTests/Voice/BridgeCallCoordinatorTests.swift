// Copyright PolyAI Limited

import XCTest
@_spi(PolyVoice) @testable import PolyMessaging

/// Deterministic tests of the full `webrtc-bridge` call pipeline, driven over
/// fakes: no sockets, no WebRTC, no network.
final class BridgeCallCoordinatorTests: XCTestCase {

    private func makeCoordinator(
        api: MockRestApi = MockRestApi(),
        bridge: FakeBridgeApi = FakeBridgeApi(),
        conn: MockConnection = MockConnection(),
        channel: MockSignalingChannel = MockSignalingChannel(),
        media: BridgeStubMediaEngine = BridgeStubMediaEngine(),
        connectionTimeoutNanos: UInt64 = 30_000_000_000
    ) -> BridgeCallCoordinator {
        let logger = OSLogLogger(level: .none)
        let linker = VoiceSessionLinker(
            connection: conn,
            wsBaseURL: URL(string: "wss://messaging.test/ws")!,
            logger: logger
        )
        return BridgeCallCoordinator(
            api: api,
            bridge: bridge,
            linker: linker,
            media: media,
            makeEventsChannel: { _ in channel },
            streamingEnabled: true,
            logger: logger,
            connectionTimeoutNanos: connectionTimeoutNanos,
            iceQuiet: 0.01,
            iceCap: 0.05
        )
    }

    /// Runs `start()` to completion: releases the messaging link with a
    /// SESSION_START, then reports media as connected so the agent-track pull
    /// (which the real bridge gates on a connected peer) can run.
    private func connect(
        _ coord: BridgeCallCoordinator,
        conn: MockConnection,
        media: BridgeStubMediaEngine
    ) async throws {
        let startTask = Task { try await coord.start() }
        let linked = await waitUntil { conn.connectCalls.count == 1 }
        XCTAssertTrue(linked, "linker opens the messaging WS")
        conn.simulateMessage(.sessionStart(makeEnvelope(), makeSessionStartPayload()))
        // The pipeline suspends until media reports connected.
        let offered = await waitUntil { media.acceptedAnswer != nil }
        XCTAssertTrue(offered, "the answer is applied before we wait for media")
        media.driveState(.connected)
        try await startTask.value
    }

    // MARK: - Happy path

    func test_pipeline_provisions_links_offers_pulls_andConnects() async throws {
        let bridge = FakeBridgeApi()
        let conn = MockConnection()
        let media = BridgeStubMediaEngine()
        let coord = makeCoordinator(bridge: bridge, conn: conn, media: media)

        try await connect(coord, conn: conn, media: media)

        XCTAssertEqual(bridge.provisionCount, 1)
        XCTAssertEqual(bridge.sentOffers.count, 1)
        XCTAssertEqual(bridge.pullCount, 1, "the agent track is pulled on connect")
        XCTAssertEqual(bridge.renegotiatedAnswers.count, 1)
        let state = await coord.state
        XCTAssertEqual(state, .connected)
    }

    /// The migration's central ordering change: the bridge mints the call id, so
    /// the messaging session can only be linked after provision returns — and it
    /// must be linked to *that* id, not a client-generated UUID.
    func test_messagingSessionIsLinkedToTheBridgeMintedCallId() async throws {
        let bridge = FakeBridgeApi()
        let conn = MockConnection()
        let media = BridgeStubMediaEngine()
        let coord = makeCoordinator(bridge: bridge, conn: conn, media: media)

        try await connect(coord, conn: conn, media: media)

        let linkFrames = conn.sentRawData
            .compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .filter { ($0["type"] as? String) == "EVENT_TYPE_LINK_TO_WEBRTC_CONVERSATION" }
        XCTAssertEqual(linkFrames.count, 1)
        let payload = try XCTUnwrap(linkFrames.first?["payload"] as? [String: Any])
        XCTAssertEqual(payload["call_sid"] as? String, "call-5f9ec645")
    }

    func test_provisionHappensBeforeTheMessagingLink() async throws {
        let bridge = FakeBridgeApi()
        let conn = MockConnection()
        let coord = makeCoordinator(bridge: bridge, conn: conn)

        let startTask = Task { try await coord.start() }
        // The linker's WS open is the first observable step after provision, so
        // by the time it happens the provision must already have completed.
        let linked = await waitUntil { conn.connectCalls.count == 1 }
        XCTAssertTrue(linked)
        XCTAssertEqual(bridge.provisionCount, 1, "provision precedes the link")
        startTask.cancel()
        await coord.end()
    }

    /// Non-trickle: what goes to the bridge must be the description read back
    /// *after* the gather wait, never the SDP `createOffer` returned.
    func test_offerPostedIsTheGatheredDescription() async throws {
        let bridge = FakeBridgeApi()
        let conn = MockConnection()
        let media = BridgeStubMediaEngine()
        media.gatheredSDP = "v=0\r\nwith-candidates"
        media.mid = "7"
        let coord = makeCoordinator(bridge: bridge, conn: conn, media: media)

        try await connect(coord, conn: conn, media: media)

        XCTAssertEqual(bridge.sentOffers.first?.sdp, "v=0\r\nwith-candidates")
        XCTAssertEqual(bridge.sentOffers.first?.mid, "7")
        XCTAssertGreaterThanOrEqual(media.gatherWaits, 2, "offer and renegotiation each wait for gathering")
    }

    func test_offerFailsWhenTheEngineExposesNoGatheredDescription() async throws {
        let conn = MockConnection()
        let media = BridgeStubMediaEngine()
        media.gatheredSDP = nil
        let coord = makeCoordinator(conn: conn, media: media)

        let startTask = Task { try await coord.start() }
        _ = await waitUntil { conn.connectCalls.count == 1 }
        conn.simulateMessage(.sessionStart(makeEnvelope(), makeSessionStartPayload()))

        do {
            try await startTask.value
            XCTFail("expected a media failure")
        } catch {
            guard case .voice(.mediaFailed) = error as? PolyError ?? .voice(.timedOut) else {
                return XCTFail("expected .mediaFailed, got \(error)")
            }
        }
    }

    /// Media terminates at Cloudflare on this path, so Cloudflare's STUN is the
    /// fallback — never the gateway's Google STUN default.
    func test_iceServers_fallBackToCloudflareStun() async throws {
        let conn = MockConnection()
        let media = BridgeStubMediaEngine()
        let coord = makeCoordinator(conn: conn, media: media)

        try await connect(coord, conn: conn, media: media)

        XCTAssertEqual(media.lastIceServers, IceServer.bridgeDefaultServers)
        XCTAssertEqual(media.lastIceServers.first?.urls, ["stun:stun.cloudflare.com:3478"])
    }

    func test_iceServers_preferTheBridgeSuppliedList() async throws {
        var provision = FakeBridgeApi.defaultProvision
        provision = BridgeProtocol.Provision(
            callId: provision.callId,
            credentials: BridgeProtocol.Credentials(
                provider: provision.credentials.provider,
                connectPath: provision.credentials.connectPath,
                token: provision.credentials.token,
                trackName: provision.credentials.trackName,
                iceServers: [IceServer(urls: ["turn:turn.dev.polyai.app:3478"], username: "u", credential: "c")],
                eventsPath: provision.credentials.eventsPath,
                pullPath: provision.credentials.pullPath,
                renegotiatePath: provision.credentials.renegotiatePath
            )
        )
        let conn = MockConnection()
        let media = BridgeStubMediaEngine()
        let coord = makeCoordinator(bridge: FakeBridgeApi(provision: provision), conn: conn, media: media)

        try await connect(coord, conn: conn, media: media)

        XCTAssertEqual(media.lastIceServers.first?.urls, ["turn:turn.dev.polyai.app:3478"])
    }

    // MARK: - Events socket

    func test_eventsSocket_sendsTheAuthFrameFirst() async throws {
        let channel = MockSignalingChannel()
        let conn = MockConnection()
        let media = BridgeStubMediaEngine()
        let coord = makeCoordinator(conn: conn, channel: channel, media: media)

        try await connect(coord, conn: conn, media: media)
        channel.emit(.opened)

        let sent = await waitUntil { !channel.sentFrames.isEmpty }
        XCTAssertTrue(sent, "auth frame is sent on open")
        let frame = channel.sentJSON().first
        XCTAssertEqual(frame?["type"] as? String, "auth")
        XCTAssertEqual(frame?["token"] as? String, FakeBridgeApi.defaultProvision.credentials.token)
    }

    func test_repullEvent_pullsTheAgentTrackAgain() async throws {
        let bridge = FakeBridgeApi()
        let channel = MockSignalingChannel()
        let conn = MockConnection()
        let media = BridgeStubMediaEngine()
        let coord = makeCoordinator(bridge: bridge, conn: conn, channel: channel, media: media)

        try await connect(coord, conn: conn, media: media)
        XCTAssertEqual(bridge.pullCount, 1)

        channel.emit(.opened)
        channel.emit(.message(Data(#"{"event":"repull"}"#.utf8)))

        let repulled = await waitUntil { bridge.pullCount == 2 }
        XCTAssertTrue(repulled, "a repull event re-subscribes to the agent track")
        XCTAssertEqual(bridge.renegotiatedAnswers.count, 2)
    }

    /// Two renegotiations must never interleave on one peer connection, so
    /// overlapping re-pulls are chained.
    func test_overlappingRepulls_areSerialised() async throws {
        let bridge = FakeBridgeApi()
        let channel = MockSignalingChannel()
        let conn = MockConnection()
        let media = BridgeStubMediaEngine()
        let coord = makeCoordinator(bridge: bridge, conn: conn, channel: channel, media: media)

        try await connect(coord, conn: conn, media: media)
        channel.emit(.opened)
        for _ in 0..<5 { channel.emit(.message(Data(#"{"event":"repull"}"#.utf8))) }

        let done = await waitUntil { bridge.pullCount == 6 }
        XCTAssertTrue(done, "every repull ran (got \(bridge.pullCount))")
        // One renegotiation per pull, never more: an interleaved pair would
        // renegotiate twice off one pull.
        XCTAssertEqual(bridge.renegotiatedAnswers.count, bridge.pullCount)
    }

    func test_bargeInAndUnmute_controlTheAgentTrack() async throws {
        let channel = MockSignalingChannel()
        let conn = MockConnection()
        let media = BridgeStubMediaEngine()
        let coord = makeCoordinator(conn: conn, channel: channel, media: media)

        try await connect(coord, conn: conn, media: media)
        channel.emit(.opened)
        channel.emit(.message(Data(#"{"event":"barge-in"}"#.utf8)))
        let muted = await waitUntil { media.remoteAudioEnabled == [false] }
        XCTAssertTrue(muted, "barge-in silences the agent immediately")

        channel.emit(.message(Data(#"{"event":"unmute"}"#.utf8)))
        let restored = await waitUntil { media.remoteAudioEnabled == [false, true] }
        XCTAssertTrue(restored, "the agent resumes on unmute")
    }

    func test_eventsSocketLoss_afterConnect_endsTheCall() async throws {
        let channel = MockSignalingChannel()
        let conn = MockConnection()
        let media = BridgeStubMediaEngine()
        let coord = makeCoordinator(conn: conn, channel: channel, media: media)

        try await connect(coord, conn: conn, media: media)
        channel.emit(.closed(code: 1006, reason: "dropped"))

        let ended = await waitUntil { await coord.state == .ended }
        XCTAssertTrue(ended, "losing the control socket ends the call rather than running blind")
    }

    // MARK: - Teardown

    func test_end_deletesTheCallAndReleasesEverything() async throws {
        let bridge = FakeBridgeApi()
        let channel = MockSignalingChannel()
        let conn = MockConnection()
        let media = BridgeStubMediaEngine()
        let coord = makeCoordinator(bridge: bridge, conn: conn, channel: channel, media: media)

        try await connect(coord, conn: conn, media: media)
        await coord.end()

        XCTAssertEqual(bridge.deleteCount, 1, "DELETE /api/v1/call/{id} replaces the gateway's close frame")
        XCTAssertEqual(media.closeCount, 1)
        XCTAssertTrue(channel.closeCalled)
        let endState = await coord.state
        XCTAssertEqual(endState, .ended)
    }

    func test_provisionFailure_failsTheCallWithoutLinking() async {
        let bridge = FakeBridgeApi()
        bridge.provisionError = PolyError.voice(.signalingFailed("Bridge provision rejected the call credentials (401)"))
        let conn = MockConnection()
        let coord = makeCoordinator(bridge: bridge, conn: conn)

        do {
            try await coord.start()
            XCTFail("expected the provision failure to surface")
        } catch {
            XCTAssertEqual(error as? PolyError, .voice(.signalingFailed("Bridge provision rejected the call credentials (401)")))
        }
        XCTAssertEqual(conn.connectCalls.count, 0, "no messaging link without a call id")
        if case .failed = await coord.state {} else { XCTFail("expected .failed") }
    }

    func test_mute_appliesToTheMicrophone() async throws {
        let conn = MockConnection()
        let media = BridgeStubMediaEngine()
        let coord = makeCoordinator(conn: conn, media: media)

        try await connect(coord, conn: conn, media: media)
        await coord.setMuted(true)
        XCTAssertEqual(media.muted, true)
        let muted = await coord.isMuted
        XCTAssertTrue(muted)

        await coord.setMuted(false)
        XCTAssertEqual(media.muted, false)
    }

    func test_connectTimeout_failsTheCall() async {
        let conn = MockConnection()
        let media = BridgeStubMediaEngine()
        let coord = makeCoordinator(conn: conn, media: media, connectionTimeoutNanos: 100_000_000)

        let startTask = Task { try? await coord.start() }
        _ = await waitUntil { conn.connectCalls.count == 1 }
        conn.simulateMessage(.sessionStart(makeEnvelope(), makeSessionStartPayload()))
        // Media never connects.
        let failed = await waitUntil(timeout: 3) {
            if case .failed(.voice(.timedOut)) = await coord.state { return true }
            return false
        }
        XCTAssertTrue(failed, "a call whose media never connects times out")
        startTask.cancel()
    }
}
