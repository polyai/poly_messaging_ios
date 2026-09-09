// Copyright PolyAI Limited

import XCTest
@_spi(PolyVoice) @testable import PolyMessaging

/// Stress / race probes for the voice-call lifecycle (the voice twin of the
/// chat `StressLifecycleRace` / `StressReconnectStorm` suites). Invariants:
///  1. `start()` is idempotent and `end()` mid-`start()` aborts the pipeline
///     cleanly (no offer into a dead call, resources released).
///  2. Terminal states are sticky: `end()` after a failure must not repaint
///     `.failed` as `.ended`, and repeated `end()` tears down exactly once.
///  3. A burst of `repull` events can never interleave two renegotiations on
///     one peer connection.
///  4. The call is deleted server-side exactly once, however it ends.
///
/// The gateway's reconnect-storm and ICE-buffering probes retired with the
/// gateway: the bridge has no candidate channel, and a lost control socket ends
/// the call rather than reconnecting.
final class StressCallLifecycleTests: XCTestCase {

    private func makeCoordinator(
        api: MockRestApi = MockRestApi(),
        bridge: FakeBridgeApi = FakeBridgeApi(),
        conn: MockConnection = MockConnection(),
        channel: MockEventsChannel = MockEventsChannel(),
        media: StubMediaEngine = StubMediaEngine()
    ) -> BridgeCallCoordinator {
        let logger = NoopLogger()
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
            iceQuiet: 0.01,
            iceCap: 0.05
        )
    }

    /// Drive `start()` to a connected call.
    @discardableResult
    private func connect(
        _ coord: BridgeCallCoordinator,
        conn: MockConnection,
        media: StubMediaEngine
    ) async throws -> Bool {
        let startTask = Task { try await coord.start() }
        _ = await waitUntil { conn.connectCalls.count == 1 }
        conn.simulateMessage(.sessionStart(makeEnvelope(), makeSessionStartPayload()))
        try await startTask.value
        _ = await waitUntil { media.acceptedAnswer != nil }
        media.driveState(.connected)
        // The agent-track pull runs on after start() returns.
        return await waitUntil { !media.acceptedOffers.isEmpty }
    }

    // MARK: - 1. start / end races

    func test_start_isIdempotent() async throws {
        let bridge = FakeBridgeApi()
        let conn = MockConnection()
        let media = StubMediaEngine()
        let coord = makeCoordinator(bridge: bridge, conn: conn, media: media)

        try await connect(coord, conn: conn, media: media)
        // A second start() on a live call must be a no-op — not a second call
        // provisioned server-side.
        try await coord.start()

        XCTAssertEqual(bridge.provisionCount, 1, "a live call is never re-provisioned")
        XCTAssertEqual(conn.connectCalls.count, 1)
    }

    func test_endDuringStart_abortsBeforeTheOfferIsSent() async throws {
        let bridge = FakeBridgeApi()
        let conn = MockConnection()
        let coord = makeCoordinator(bridge: bridge, conn: conn)

        let startTask = Task { try? await coord.start() }
        // End while the pipeline is still waiting on the messaging link.
        _ = await waitUntil { conn.connectCalls.count == 1 }
        await coord.end()
        conn.simulateMessage(.sessionStart(makeEnvelope(), makeSessionStartPayload()))
        _ = await startTask.value

        XCTAssertTrue(bridge.sentOffers.isEmpty, "no offer is POSTed into a call that already ended")
        let state = await coord.state
        XCTAssertEqual(state, .ended)
    }

    func test_endDuringStart_stillDeletesTheProvisionedCall() async throws {
        let bridge = FakeBridgeApi()
        let conn = MockConnection()
        let coord = makeCoordinator(bridge: bridge, conn: conn)

        let startTask = Task { try? await coord.start() }
        _ = await waitUntil { bridge.provisionCount == 1 }
        await coord.end()
        _ = await startTask.value

        // The bridge minted a call; abandoning it without a DELETE would leak a
        // session until the server reaped it.
        let deleted = await waitUntil { bridge.deleteCount == 1 }
        XCTAssertTrue(deleted, "an aborted start still tears down the provisioned call")
    }

    // MARK: - 2. sticky terminal states

    func test_endAfterFailure_doesNotRepaintTheState() async throws {
        let bridge = FakeBridgeApi()
        bridge.sendOfferError = PolyError.voice(.signalingFailed("bridge sdp failed (502)"))
        let conn = MockConnection()
        let media = StubMediaEngine()
        let coord = makeCoordinator(bridge: bridge, conn: conn, media: media)

        let startTask = Task { try? await coord.start() }
        _ = await waitUntil { conn.connectCalls.count == 1 }
        conn.simulateMessage(.sessionStart(makeEnvelope(), makeSessionStartPayload()))
        _ = await startTask.value

        let failed = await waitUntil {
            if case .failed = await coord.state { return true }
            return false
        }
        XCTAssertTrue(failed)

        await coord.end()
        let state = await coord.state
        guard case .failed = state else {
            return XCTFail("a failure must not be repainted as .ended, got \(state)")
        }
    }

    func test_repeatedEnd_tearsDownExactlyOnce() async throws {
        let bridge = FakeBridgeApi()
        let conn = MockConnection()
        let media = StubMediaEngine()
        let coord = makeCoordinator(bridge: bridge, conn: conn, media: media)

        try await connect(coord, conn: conn, media: media)
        await coord.end()
        await coord.end()
        await coord.end()

        XCTAssertEqual(media.closeCount, 1, "the media engine is released once")
        XCTAssertEqual(bridge.deleteCount, 1, "the call is deleted once")
    }

    // MARK: - 3. renegotiation storms

    func test_repullStorm_neverInterleavesTwoRenegotiations() async throws {
        let bridge = FakeBridgeApi()
        let conn = MockConnection()
        let channel = MockEventsChannel()
        let media = StubMediaEngine()
        let coord = makeCoordinator(bridge: bridge, conn: conn, channel: channel, media: media)

        try await connect(coord, conn: conn, media: media)
        channel.emit(.opened)
        for _ in 0..<20 { channel.emit(.message(Data(#"{"event":"repull"}"#.utf8))) }

        let settled = await waitUntil(timeout: 10) { bridge.pullCount == 21 }
        XCTAssertTrue(settled, "every repull ran (got \(bridge.pullCount))")
        // One renegotiation per pull. Interleaving would produce a different
        // count — two answers off one pull, or a pull whose answer never lands.
        XCTAssertEqual(bridge.renegotiatedAnswers.count, bridge.pullCount)
        XCTAssertEqual(media.acceptedOffers.count, bridge.pullCount)
    }

    func test_repullAfterEnd_isDropped() async throws {
        let bridge = FakeBridgeApi()
        let conn = MockConnection()
        let channel = MockEventsChannel()
        let media = StubMediaEngine()
        let coord = makeCoordinator(bridge: bridge, conn: conn, channel: channel, media: media)

        try await connect(coord, conn: conn, media: media)
        let pullsAtEnd = bridge.pullCount
        await coord.end()
        channel.emit(.message(Data(#"{"event":"repull"}"#.utf8)))

        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(bridge.pullCount, pullsAtEnd, "a repull after teardown does nothing")
    }

    // MARK: - 4. failure paths still clean up

    func test_pullFailure_failsTheCallAndReleasesResources() async throws {
        let bridge = FakeBridgeApi()
        bridge.pullError = PolyError.voice(.signalingFailed("bridge pull failed (502)"))
        let conn = MockConnection()
        let media = StubMediaEngine()
        let coord = makeCoordinator(bridge: bridge, conn: conn, media: media)

        let startTask = Task { try? await coord.start() }
        _ = await waitUntil { conn.connectCalls.count == 1 }
        conn.simulateMessage(.sessionStart(makeEnvelope(), makeSessionStartPayload()))
        _ = await startTask.value
        _ = await waitUntil { media.acceptedAnswer != nil }
        media.driveState(.connected)

        let cleanedUp = await waitUntil { media.closeCount == 1 && bridge.deleteCount == 1 }
        XCTAssertTrue(cleanedUp, "a failed agent-track pull still releases the mic and deletes the call")
    }

    func test_rapidStartEndCycles_leaveNothingRunning() async throws {
        for _ in 0..<5 {
            let bridge = FakeBridgeApi()
            let conn = MockConnection()
            let media = StubMediaEngine()
            let coord = makeCoordinator(bridge: bridge, conn: conn, media: media)

            try await connect(coord, conn: conn, media: media)
            await coord.end()

            XCTAssertEqual(media.closeCount, 1)
            XCTAssertEqual(bridge.deleteCount, 1)
            let state = await coord.state
            XCTAssertEqual(state, .ended)
        }
    }
}
