// Copyright PolyAI Limited

import Foundation

/// Orchestrates a voice call over `webrtc-bridge` (RUN-1279).
///
/// The gateway twin of this type is ``CallCoordinator``. The difference is not
/// the transport alone — the whole shape of the handshake changes:
///
/// | | gateway | bridge |
/// |---|---|---|
/// | credential | `authToken` inside the offer | `Authorization: Bearer` on provision |
/// | signalling | one WebSocket, trickle ICE | HTTPS for SDP + a control socket |
/// | call id | client mints it, links, then calls | bridge mints it, so provision comes first |
/// | agent audio | arrives on the single answer | a second negotiation (pull → answer → renegotiate) |
///
/// Pipeline:
///   1. access token                    (`RestApiPort.obtainAccessToken`)
///   2. messaging session               (`RestApiPort.createSession`)
///   3. provision the call              (`BridgeApiPort.provision`) — **before** the link,
///      because the bridge mints the identifier the link has to carry
///   4. link the messaging session      (`VoiceSessionLinker`, with the bridge's `callId`)
///   5. offer, gathered, over HTTPS     (`CallMediaEngine` → `POST {connectUrl}`)
///   6. media connects
///   7. pull the agent track            (`POST {pullUrl}` → answer → `POST {renegotiateUrl}`)
///   8. events socket for barge-in and re-pull control
actor BridgeCallCoordinator: CallDriver {

    private let api: RestApiPort
    private let bridge: BridgeApiPort
    private let linker: VoiceSessionLinker
    private let media: CallMediaEngine
    private let makeEventsChannel: @Sendable (URL) -> SignalingChannel
    private let streamingEnabled: Bool
    private let logger: PolyLogger

    private let stateCaster = Multicaster<CallState>(replayLastValue: true)
    private let audioCaster = Multicaster<AudioState>(replayLastValue: true)
    private(set) var state: CallState = .idle

    private var active = false
    private var provision: BridgeProtocol.Provision?
    private var events: SignalingChannel?
    private var lastMediaState: CallMediaState = .new
    private var hasConnected = false
    private var userMuted = false
    private var interruptionMuted = false

    private var eventLoopTask: Task<Void, Never>?
    private var connectTimeoutTask: Task<Void, Never>?
    private var teardownTask: Task<Void, Never>?
    private var mediaStateTask: Task<Void, Never>?
    private var mediaStateSink: AsyncStream<CallMediaState>.Continuation?
    /// Serialises agent-track pulls. Two renegotiations must never interleave on
    /// one peer connection, and `repull` events can arrive while the first pull
    /// is still in flight.
    private var pullTask: Task<Void, Error>?
    private var mediaConnectedWaiters: [CheckedContinuation<Void, Never>] = []

    private let connectionTimeoutNanos: UInt64
    private let iceQuiet: TimeInterval
    private let iceCap: TimeInterval

    init(
        api: RestApiPort,
        bridge: BridgeApiPort,
        linker: VoiceSessionLinker,
        media: CallMediaEngine,
        makeEventsChannel: @escaping @Sendable (URL) -> SignalingChannel,
        streamingEnabled: Bool,
        logger: PolyLogger,
        connectionTimeoutNanos: UInt64 = 30_000_000_000,
        iceQuiet: TimeInterval = 0.2,
        iceCap: TimeInterval = 2.0
    ) {
        self.api = api
        self.bridge = bridge
        self.linker = linker
        self.media = media
        self.makeEventsChannel = makeEventsChannel
        self.streamingEnabled = streamingEnabled
        self.logger = logger
        self.connectionTimeoutNanos = connectionTimeoutNanos
        self.iceQuiet = iceQuiet
        self.iceCap = iceCap
    }

    nonisolated var stateStream: AsyncStream<CallState> { stateCaster.subscribe() }
    nonisolated var audioStream: AsyncStream<AudioState> { audioCaster.subscribe() }

    // MARK: - Lifecycle

    func start() async throws {
        guard !active else { return }
        active = true
        setState(.connecting)

        await attachMediaHandlers()
        startConnectTimeout()

        do {
            let token = try await api.obtainAccessToken().accessToken
            try ensureActive()

            let session = try await api.createSession(
                context: SessionContext(
                    platform: "ios",
                    deviceType: DeviceTypeDetector.detect().rawValue,
                    streamingEnabled: streamingEnabled
                )
            )
            try ensureActive()

            // Provision BEFORE the link: the bridge mints `call-<8 hex>` and
            // accepts no client identifier, so the id the messaging session must
            // be linked to doesn't exist until this call returns.
            let call = try await bridge.provision()
            provision = call
            try ensureActive()

            try await linker.open(accessToken: token, sessionId: session.sessionId, callSid: call.callId)
            try ensureActive()

            try await negotiate(call)
            try ensureActive()

            await openEventsSocket(call)
            logger.debug("Bridge call negotiated", metadata: ["callId": call.callId])
        } catch {
            let mapped = mapError(error)
            fail(mapped)
            throw mapped
        }
    }

    func end() async {
        if active {
            logger.debug("Bridge call ending", metadata: nil)
            teardown()
            setState(.ended)
        }
        await teardownTask?.value
    }

    func setMuted(_ muted: Bool) async {
        userMuted = muted
        await applyMicState()
    }

    var isMuted: Bool { userMuted }

    func selectAudioDevice(_ device: AudioDevice?) async {
        await media.selectAudioDevice(device)
    }

    // MARK: - Negotiation

    /// Steps 5-7: offer over HTTPS, wait for media, then pull the agent track.
    private func negotiate(_ call: BridgeProtocol.Provision) async throws {
        let iceServers = call.credentials.iceServers.isEmpty
            ? IceServer.bridgeDefaultServers
            : call.credentials.iceServers
        _ = try await media.createOffer(iceServers: iceServers)
        try ensureActive()

        // Non-trickle: the candidates must be in the SDP before it is POSTed.
        await media.awaitIceGathering(quiet: iceQuiet, cap: iceCap)
        try ensureActive()

        guard let offer = await media.localDescriptionSDP() else {
            throw PolyError.voice(.mediaFailed("no gathered offer to send to the bridge"))
        }
        // "0" matches the browser client's fallback; the bridge prefers the mid
        // it reads out of the offer anyway.
        let mid = await media.audioMid() ?? "0"

        let answer = try await bridge.sendOffer(call, sdp: offer, mid: mid)
        try ensureActive()
        try await media.acceptAnswer(sdp: answer)

        // Cloudflare rejects the agent-track pull until the peer connection is
        // up, so this wait is part of the handshake, not just an observation.
        try await waitForMediaConnected()
        try await pullAgentTrack(call)
    }

    /// Subscribe to the agent track: the pull returns an offer we answer and
    /// hand back. Runs on connect and on every server-requested re-pull.
    private func pullAgentTrack(_ call: BridgeProtocol.Provision) async throws {
        let offer = try await bridge.pullAgentTrack(call)
        try ensureActive()
        let answer = try await media.acceptRemoteOffer(sdp: offer)
        await media.awaitIceGathering(quiet: iceQuiet, cap: iceCap)
        try ensureActive()
        // Prefer the post-gathering description; the answer returned by the
        // engine is still valid if it doesn't expose one.
        let gathered = await media.localDescriptionSDP() ?? answer
        try await bridge.renegotiate(call, answerSdp: gathered)
        logger.debug("Agent track pulled", metadata: ["callId": call.callId])
    }

    /// Queue a re-pull behind any in-flight one. Two renegotiations interleaving
    /// on a single peer connection is a broken call, so they are chained rather
    /// than run concurrently.
    private func queuePull() {
        guard active, let call = provision else { return }
        let previous = pullTask
        pullTask = Task { [weak self] in
            _ = try? await previous?.value
            guard let self, await self.isActive else { return }
            do {
                try await self.pullAgentTrack(call)
            } catch {
                await self.logPullFailure(error)
            }
        }
    }

    private var isActive: Bool { active }

    private func logPullFailure(_ error: Error) {
        logger.warn("Agent-track re-pull failed", metadata: ["error": String(describing: error)])
    }

    // MARK: - Events socket

    private func openEventsSocket(_ call: BridgeProtocol.Provision) async {
        guard let url = bridge.eventsURL(call) else {
            logger.warn("Bridge offered no events socket — barge-in and re-pull are unavailable", metadata: nil)
            return
        }
        let channel = makeEventsChannel(url)
        events = channel
        startEventsLoop(channel)
        await channel.open()
    }

    private func startEventsLoop(_ channel: SignalingChannel) {
        eventLoopTask?.cancel()
        eventLoopTask = Task { [weak self] in
            for await event in channel.events {
                await self?.handleChannelEvent(event)
            }
        }
    }

    private func handleChannelEvent(_ event: SignalingChannelEvent) async {
        switch event {
        case .opened:
            // A WebSocket upgrade can't carry X-Call-Token, so the same token
            // goes down the socket as its first frame. The bridge closes the
            // socket on anything else.
            guard let token = provision?.credentials.token,
                  let frame = BridgeProtocol.eventsAuthFrame(token: token) else { return }
            await events?.send(frame)
        case .message(let data):
            guard let event = BridgeProtocol.parseEvent(data) else { return }
            switch event {
            case .repull: queuePull()
            case .bargeIn: await media.setRemoteAudioEnabled(false)
            case .unmute: await media.setRemoteAudioEnabled(true)
            }
        case .closed(let code, _):
            // The socket is the only channel that can drive the call once media
            // is up; losing it means barge-in and re-pull stop working, so end
            // rather than run blind. A clean 1000 is the bridge hanging up.
            guard active else { return }
            logger.warn("Bridge events socket closed (\(code))", metadata: nil)
            if code == 1000 || hasConnected {
                await end()
            } else {
                fail(.voice(.signalingFailed("Bridge events socket closed (\(code))")))
            }
        case .failed(let underlying):
            guard active else { return }
            logger.error("Bridge events socket failed", metadata: ["error": String(describing: underlying)])
            fail(hasConnected ? .voice(.disconnected) : .voice(.signalingFailed("Bridge events socket failed")))
        }
    }

    // MARK: - Media

    private func attachMediaHandlers() async {
        // The bridge has no candidate channel; local candidates land in the SDP
        // instead, so nothing is forwarded per-candidate here.
        var sink: AsyncStream<CallMediaState>.Continuation!
        let mediaStates = AsyncStream<CallMediaState> { sink = $0 }
        let continuation = sink!
        mediaStateSink = continuation
        mediaStateTask = Task { [weak self] in
            for await mediaState in mediaStates {
                await self?.handleMediaState(mediaState)
            }
        }
        await media.setStateHandler { mediaState in
            continuation.yield(mediaState)
        }
        await media.setInterruptionHandler { [weak self] interruption in
            Task { await self?.handleInterruption(interruption) }
        }
        await media.setAudioStateHandler { [weak self] audioState in
            Task { await self?.emitAudioState(audioState) }
        }
    }

    private func handleMediaState(_ mediaState: CallMediaState) async {
        guard active else { return }
        lastMediaState = mediaState
        switch mediaState {
        case .connected:
            if !hasConnected {
                hasConnected = true
                connectTimeoutTask?.cancel()
                setState(.connected)
            }
            resumeMediaConnectedWaiters()
        case .failed:
            fail(hasConnected ? .voice(.disconnected) : .voice(.mediaFailed("media connection failed")))
        case .closed:
            if hasConnected { await end() }
        case .new, .connecting, .disconnected:
            break
        }
    }

    /// Suspend until media reports `.connected` (or the call fails/ends).
    private func waitForMediaConnected() async throws {
        if hasConnected { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            mediaConnectedWaiters.append(continuation)
        }
        try ensureActive()
        guard hasConnected else {
            throw PolyError.voice(.mediaFailed("media did not connect"))
        }
    }

    private func resumeMediaConnectedWaiters() {
        let waiters = mediaConnectedWaiters
        mediaConnectedWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func emitAudioState(_ state: AudioState) {
        audioCaster.emit(state)
    }

    private func applyMicState() async {
        await media.setMuted(userMuted || interruptionMuted)
    }

    private func handleInterruption(_ interruption: CallInterruption) async {
        guard active else { return }
        switch interruption {
        case .began:
            interruptionMuted = true
            await applyMicState()
        case .endedResume:
            interruptionMuted = false
            await applyMicState()
        case .endedStop:
            logger.debug("Audio interrupted — ending bridge call", metadata: nil)
            fail(.voice(.interrupted))
        }
    }

    // MARK: - Teardown

    private func startConnectTimeout() {
        connectTimeoutTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.connectionTimeoutNanos)
            guard !Task.isCancelled else { return }
            await self.failIfNotConnected()
        }
    }

    private func failIfNotConnected() {
        guard active, !hasConnected else { return }
        fail(.voice(.timedOut))
    }

    private func ensureActive() throws {
        guard active else { throw PolyError.voice(.signalingFailed("call ended during setup")) }
    }

    private func fail(_ error: PolyError) {
        guard active else { return }
        teardown()
        setState(.failed(error))
    }

    private func teardown() {
        active = false
        connectTimeoutTask?.cancel()
        eventLoopTask?.cancel()
        pullTask?.cancel()
        mediaStateSink?.finish()
        mediaStateTask?.cancel()
        resumeMediaConnectedWaiters()

        let events = self.events
        let linker = self.linker
        let media = self.media
        let bridge = self.bridge
        let call = self.provision
        self.events = nil
        // DELETE last: the socket close is what the bridge reaps on, and the
        // teardown task is awaited by end() so a follow-up call can't race it.
        teardownTask = Task {
            await events?.close()
            await linker.close()
            await media.close()
            if let call { await bridge.deleteCall(call) }
        }
    }

    private func setState(_ newState: CallState) {
        state = newState
        stateCaster.emit(newState)
    }

    private func mapError(_ error: Error) -> PolyError {
        if let polyError = error as? PolyError { return polyError }
        return .voice(.signalingFailed(error.localizedDescription))
    }
}
