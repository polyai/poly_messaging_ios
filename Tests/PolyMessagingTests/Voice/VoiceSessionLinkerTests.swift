// Copyright PolyAI Limited

import XCTest
@_spi(PolyVoice) @testable import PolyMessaging

/// Unit tests for `VoiceSessionLinker` — the messaging-WS leg of a voice call —
/// against a `MockConnection`. Previously this component was only exercised by
/// the opt-in live bridge probe; these tests pin its contract deterministically:
/// URL shape, SESSION_START gating, the link frame, timeout, and the
/// tolerate-send-failure policy the pipeline relies on.
final class VoiceSessionLinkerTests: XCTestCase {

    private func makeLinker(
        conn: MockConnection,
        wsBase: String = "wss://messaging.test/ws"
    ) -> VoiceSessionLinker {
        VoiceSessionLinker(
            connection: conn,
            wsBaseURL: URL(string: wsBase)!,
            logger: NoopLogger()
        )
    }

    /// Starts `open()` and returns once the linker has connected the WS,
    /// leaving it awaiting SESSION_START.
    private func openInFlight(
        _ linker: VoiceSessionLinker,
        conn: MockConnection,
        callSid: String = "call_1",
        timeout: TimeInterval = 15
    ) async -> Task<Void, Error> {
        let task = Task {
            try await linker.open(
                accessToken: "tok_abc",
                sessionId: "sess_1",
                callSid: callSid,
                timeout: timeout
            )
        }
        let connected = await waitUntil { conn.connectCalls.count == 1 }
        XCTAssertTrue(connected, "open() connects the messaging WS")
        return task
    }

    private func linkFrames(_ conn: MockConnection) -> [[String: Any]] {
        conn.sentRawData
            .compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .filter { ($0["type"] as? String) == "EVENT_TYPE_LINK_TO_WEBRTC_CONVERSATION" }
    }

    // MARK: - URL shape

    func test_open_appendsAuthAndSessionQuery() async throws {
        let conn = MockConnection()
        let linker = makeLinker(conn: conn, wsBase: "wss://messaging.test/ws?region=us")
        let task = await openInFlight(linker, conn: conn)

        let url = try XCTUnwrap(conn.connectCalls.first)
        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = comps.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "access_token" }?.value, "tok_abc")
        XCTAssertEqual(items.first { $0.name == "session_id" }?.value, "sess_1")
        XCTAssertEqual(items.first { $0.name == "region" }?.value, "us",
                       "query params already on the base URL are preserved, not replaced")
        XCTAssertEqual(comps.host, "messaging.test")
        XCTAssertEqual(comps.path, "/ws")

        conn.simulateMessage(.sessionStart(makeEnvelope(), makeSessionStartPayload()))
        try await task.value
    }

    // MARK: - SESSION_START gating + link frame

    func test_open_resolvesAndLinks_onSessionStart() async throws {
        let conn = MockConnection()
        let linker = makeLinker(conn: conn)
        let task = await openInFlight(linker, conn: conn, callSid: "call_9")

        // No link frame may be sent before the session has started.
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(linkFrames(conn).isEmpty, "the link frame waits for SESSION_START")

        conn.simulateMessage(.sessionStart(makeEnvelope(), makeSessionStartPayload()))
        try await task.value

        let frames = linkFrames(conn)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual((frames.first?["payload"] as? [String: Any])?["call_sid"] as? String, "call_9")
    }

    func test_open_ignoresNonSessionStartEvents() async throws {
        let conn = MockConnection()
        let linker = makeLinker(conn: conn)
        let task = await openInFlight(linker, conn: conn)

        // Unrelated traffic on the pipe must not resolve (or break) the wait.
        conn.simulateMessage(.agentMessage(makeEnvelope(), makeAgentMessagePayload()))
        conn.simulateMessage(.userTyping(makeEnvelope()))
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(linkFrames(conn).isEmpty, "non-SESSION_START events don't trigger the link")

        conn.simulateMessage(.sessionStart(makeEnvelope(), makeSessionStartPayload()))
        try await task.value
        XCTAssertEqual(linkFrames(conn).count, 1)
    }

    // MARK: - Timeout

    func test_open_timesOut_withoutSessionStart() async {
        let conn = MockConnection()
        let linker = makeLinker(conn: conn)
        let task = await openInFlight(linker, conn: conn, timeout: 0.2)

        do {
            try await task.value
            XCTFail("open() must throw when SESSION_START never arrives")
        } catch {
            XCTAssertEqual(error as? PolyError, .voice(.timedOut))
        }
        XCTAssertTrue(linkFrames(conn).isEmpty, "no link frame after a timeout")
    }

    // MARK: - Link-send failure policy

    func test_linkSendFailure_isTolerated() async throws {
        let conn = MockConnection()
        conn.nextSendRawError = .transport(.networkError("blip"))
        let linker = makeLinker(conn: conn)
        let task = await openInFlight(linker, conn: conn)

        conn.simulateMessage(.sessionStart(makeEnvelope(), makeSessionStartPayload()))
        // Linking is opportunistic: a failed link send logs and moves on, it
        // must never fail the call pipeline.
        try await task.value
        XCTAssertTrue(linkFrames(conn).isEmpty)
    }

    // MARK: - Close

    func test_close_disconnectsCleanly() async {
        let conn = MockConnection()
        let linker = makeLinker(conn: conn)
        await linker.close()
        XCTAssertEqual(conn.disconnectCalls.count, 1)
        XCTAssertEqual(conn.disconnectCalls.first?.code, 1000)
    }
}
