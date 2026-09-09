// Copyright PolyAI Limited

import XCTest
@_spi(PolyVoice) @testable import PolyMessaging

/// End-to-end *scenario* coverage for voice at the layer the example apps bind
/// to — the public `PolyCall` surface (the voice twin of the chat
/// `E2EScenarioTests`). Each test drives a real
/// `PolyCall → BridgeCallCoordinator → VoiceSessionLinker` pipeline over a
/// `MockConnection` + `FakeBridgeApi` + `MockEventsChannel` + `StubMediaEngine`
/// (no network, no WebRTC stack) and asserts what the app observes: `states`,
/// `state`, `isMuted`, and `audioState`.
@MainActor
final class VoiceE2EScenarioTests: XCTestCase {

    private struct Stack {
        let call: PolyCall
        let api: MockRestApi
        let conn: MockConnection
        let bridge: FakeBridgeApi
        let channel: MockEventsChannel
        let media: StubMediaEngine
    }

    /// Collects every `CallState` the public stream publishes, in order.
    private final class StateLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _states: [CallState] = []
        var states: [CallState] { lock.lock(); defer { lock.unlock() }; return _states }
        func append(_ state: CallState) { lock.lock(); _states.append(state); lock.unlock() }
    }

    private func makeStack() -> Stack {
        let api = MockRestApi()
        let conn = MockConnection()
        let bridge = FakeBridgeApi()
        let channel = MockEventsChannel()
        let media = StubMediaEngine()
        let logger = NoopLogger()
        let linker = VoiceSessionLinker(
            connection: conn,
            wsBaseURL: URL(string: "wss://messaging.test/ws")!,
            logger: logger
        )
        let coordinator = BridgeCallCoordinator(
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
        return Stack(call: PolyCall(coordinator: coordinator), api: api, conn: conn, bridge: bridge, channel: channel, media: media)
    }

    /// `start()` the call: feed SESSION_START so the messaging link resolves.
    /// Returns with the call `.connecting`, as the app sees it.
    private func startCall(_ stack: Stack) async throws {
        let task = Task { try await stack.call.start() }
        let linked = await waitUntil { stack.conn.connectCalls.count == 1 }
        XCTAssertTrue(linked, "start() opens the messaging WS via the linker")
        stack.conn.simulateMessage(.sessionStart(makeEnvelope(), makeSessionStartPayload()))
        try await task.value
    }

    /// Drive the negotiated call to `.connected` (media up → agent track pulled).
    private func connect(_ stack: Stack) async {
        _ = await waitUntil { stack.media.acceptedAnswer != nil }
        stack.media.driveState(.connected)
        let connected = await waitUntil { await MainActor.run { stack.call.state == .connected } }
        XCTAssertTrue(connected, "the public state reaches .connected")
        _ = await waitUntil { stack.bridge.pullCount == 1 }
    }

    private func frame(_ obj: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
    }

    // MARK: - Scenarios

    /// The example apps' whole UI is a `for await` over `call.states` — the
    /// exact progression they render must hold: connecting → connected → ended.
    func test_fullCall_publishesConnectingConnectedEnded() async throws {
        let stack = makeStack()
        let log = StateLog()
        // Subscribing registers the continuation synchronously, so every state
        // emitted from here on is buffered for the observer below.
        let stream = stack.call.states
        let observer = Task { for await state in stream { log.append(state) } }
        defer { observer.cancel() }

        try await startCall(stack)
        await connect(stack)
        await stack.call.end()

        let ended = await waitUntil { log.states.last == .ended }
        XCTAssertTrue(ended)
        XCTAssertEqual(log.states, [.connecting, .connected, .ended],
                       "the public stream publishes the exact lifecycle the UI renders")
    }

    /// A rejected provision (bad or expired web calling token) is the failure an
    /// app is most likely to hit, and it must reach the public surface as
    /// `.failed` before any messaging session is opened.
    func test_rejectedProvision_surfacesFailedState() async throws {
        let stack = makeStack()
        stack.bridge.provisionError = PolyError.voice(
            .signalingFailed("Bridge provision rejected the call credentials (401)")
        )

        do {
            try await stack.call.start()
            XCTFail("expected start() to throw")
        } catch {
            // surfaced below on the public state too
        }

        let failed = await waitUntil {
            stack.call.state == .failed(.voice(.signalingFailed("Bridge provision rejected the call credentials (401)")))
        }
        XCTAssertTrue(failed, "a rejected credential reaches the app as .failed")
        XCTAssertFalse(stack.call.state.isActive)
        XCTAssertEqual(stack.conn.connectCalls.count, 0, "no messaging session without a call")
    }

    /// Losing the control socket takes barge-in and re-pull with it, so the call
    /// ends rather than running on blind.
    func test_lostControlSocket_endsTheCall() async throws {
        let stack = makeStack()
        try await startCall(stack)
        await connect(stack)

        stack.channel.emit(.closed(code: 1006, reason: "dropped"))

        let ended = await waitUntil { stack.call.state == .ended }
        XCTAssertTrue(ended, "the app sees the call end when the bridge's control socket drops")
    }

    /// A late subscriber (e.g. a re-presented call screen) must immediately see
    /// the current state, not wait for the next transition.
    func test_lateSubscriber_replaysCurrentState() async throws {
        let stack = makeStack()
        try await startCall(stack)
        await connect(stack)

        var first: CallState?
        for await state in stack.call.states {
            first = state
            break
        }
        XCTAssertEqual(first, .connected, "late subscribers replay the live state")
    }

    func test_muteRoundTrip_reachesEngineAndReadsBack() async throws {
        let stack = makeStack()
        try await startCall(stack)
        await connect(stack)

        await stack.call.setMuted(true)
        XCTAssertEqual(stack.media.muted, true, "mute reaches the media engine")
        var muted = await stack.call.isMuted
        XCTAssertTrue(muted)

        await stack.call.setMuted(false)
        XCTAssertEqual(stack.media.muted, false)
        muted = await stack.call.isMuted
        XCTAssertFalse(muted)
    }

    func test_audioDeviceSelection_andSnapshots_flowThroughPublicSurface() async throws {
        let stack = makeStack()
        try await startCall(stack)
        await connect(stack)

        let speaker = AudioDevice(kind: .speakerphone, name: "Speaker", id: "builtin.speaker")
        await stack.call.setAudioDevice(speaker)
        XCTAssertEqual(stack.media.audioDeviceSelections.first ?? nil, speaker)

        let snapshot = AudioState(availableDevices: [speaker], selectedDevice: speaker)
        let stream = stack.call.audioStates
        stack.media.driveAudioState(snapshot)
        var received: AudioState?
        for await state in stream {
            received = state
            break
        }
        XCTAssertEqual(received, snapshot, "engine audio snapshots reach the app's picker stream")
    }

    /// "Safe to call at any time": ending a call that never started must not
    /// crash or wedge the instance.
    func test_endBeforeStart_isSafe() async throws {
        let stack = makeStack()
        await stack.call.end()
        XCTAssertEqual(stack.call.state, .idle, "no lifecycle was started, so none is published")

        // The instance is still usable afterwards.
        try await startCall(stack)
        XCTAssertEqual(stack.call.state, .connecting)
        await stack.call.end()
        let ended = await waitUntil { await MainActor.run { stack.call.state == .ended } }
        XCTAssertTrue(ended)
    }
}
