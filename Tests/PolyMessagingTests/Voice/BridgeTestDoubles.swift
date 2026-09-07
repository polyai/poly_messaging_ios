// Copyright PolyAI Limited

import Foundation
import XCTest
@_spi(PolyVoice) @testable import PolyMessaging

// MARK: - Fake bridge API

/// In-memory ``BridgeApiPort`` that records every call and lets a test fail any
/// single route. Ordering is recorded too: the bridge migration's central
/// correctness property is that provision happens **before** the messaging link.
final class FakeBridgeApi: BridgeApiPort, @unchecked Sendable {

    private let lock = NSLock()

    var provisionResult: BridgeProtocol.Provision
    var provisionError: Error?
    var answerSDP = "v=0\r\nanswer"
    var pullOffer = "v=0\r\npull-offer"
    var sendOfferError: Error?
    var pullError: Error?
    var renegotiateError: Error?

    private var _provisionCount = 0
    private var _sentOffers: [(sdp: String, mid: String)] = []
    private var _pullCount = 0
    private var _renegotiatedAnswers: [String] = []
    private var _deleteCount = 0

    var provisionCount: Int { lock.lock(); defer { lock.unlock() }; return _provisionCount }
    var sentOffers: [(sdp: String, mid: String)] { lock.lock(); defer { lock.unlock() }; return _sentOffers }
    var pullCount: Int { lock.lock(); defer { lock.unlock() }; return _pullCount }
    var renegotiatedAnswers: [String] { lock.lock(); defer { lock.unlock() }; return _renegotiatedAnswers }
    var deleteCount: Int { lock.lock(); defer { lock.unlock() }; return _deleteCount }

    init(provision: BridgeProtocol.Provision = FakeBridgeApi.defaultProvision) {
        self.provisionResult = provision
    }

    func provision() async throws -> BridgeProtocol.Provision {
        lock.lock(); _provisionCount += 1; let err = provisionError; lock.unlock()
        if let err { throw err }
        return provisionResult
    }

    func sendOffer(_ provision: BridgeProtocol.Provision, sdp: String, mid: String) async throws -> String {
        lock.lock(); _sentOffers.append((sdp, mid)); let err = sendOfferError; lock.unlock()
        if let err { throw err }
        return answerSDP
    }

    func pullAgentTrack(_ provision: BridgeProtocol.Provision) async throws -> String {
        lock.lock(); _pullCount += 1; let err = pullError; lock.unlock()
        if let err { throw err }
        return pullOffer
    }

    func renegotiate(_ provision: BridgeProtocol.Provision, answerSdp: String) async throws {
        lock.lock(); _renegotiatedAnswers.append(answerSdp); let err = renegotiateError; lock.unlock()
        if let err { throw err }
    }

    func deleteCall(_ provision: BridgeProtocol.Provision) async {
        lock.lock(); _deleteCount += 1; lock.unlock()
    }

    func eventsURL(_ provision: BridgeProtocol.Provision) -> URL? {
        URL(string: "wss://bridge.test/api/v1/call/\(provision.callId)/events")
    }

    /// Shaped exactly like a real dev-cluster provision response.
    static let defaultProvision = BridgeProtocol.Provision(
        callId: "call-5f9ec645",
        credentials: BridgeProtocol.Credentials(
            provider: "cloudflare",
            connectPath: "/api/v1/call/call-5f9ec645/sdp",
            token: "1788794409.CSOgLZEbgQ9bloJ0EE7zk8KHVNSTpogvB",
            trackName: "agent-echo",
            iceServers: [],
            eventsPath: "/api/v1/call/call-5f9ec645/events",
            pullPath: "/api/v1/call/call-5f9ec645/sdp/pull",
            renegotiatePath: "/api/v1/call/call-5f9ec645/sdp/renegotiate"
        )
    )
}

// MARK: - Bridge-capable media engine

/// ``StubMediaEngine`` with the four bridge capabilities implemented, so the
/// non-trickle / renegotiating pipeline can be driven without WebRTC.
final class BridgeStubMediaEngine: CallMediaEngine, @unchecked Sendable {

    private let lock = NSLock()
    private let inner = StubMediaEngine()

    /// SDP reported by `localDescriptionSDP()` — the "gathered" offer, distinct
    /// from what `createOffer` returns so tests can prove the POSTed SDP is the
    /// post-gathering one.
    var gatheredSDP: String? = "v=0\r\ngathered-offer"
    var mid: String? = "0"
    var answerSDP = "v=0\r\nrenegotiation-answer"
    var acceptRemoteOfferError: Error?

    private var _gatherWaits = 0
    private var _acceptedOffers: [String] = []
    private var _remoteAudioEnabled: [Bool] = []

    var gatherWaits: Int { lock.lock(); defer { lock.unlock() }; return _gatherWaits }
    var acceptedOffers: [String] { lock.lock(); defer { lock.unlock() }; return _acceptedOffers }
    var remoteAudioEnabled: [Bool] { lock.lock(); defer { lock.unlock() }; return _remoteAudioEnabled }

    var createOfferCount: Int { inner.createOfferCount }
    var acceptedAnswer: String? { inner.acceptedAnswer }
    var lastIceServers: [IceServer] { inner.lastIceServers }
    var muted: Bool? { inner.muted }
    var closeCount: Int { inner.closeCount }
    var createOfferError: Error? {
        get { inner.createOfferError }
        set { inner.createOfferError = newValue }
    }

    func createOffer(iceServers: [IceServer]) async throws -> String {
        try await inner.createOffer(iceServers: iceServers)
    }
    func acceptAnswer(sdp: String) async throws { try await inner.acceptAnswer(sdp: sdp) }
    func addRemoteCandidate(_ candidate: IceCandidate) async throws {
        try await inner.addRemoteCandidate(candidate)
    }
    func setLocalCandidateHandler(_ handler: @escaping @Sendable (IceCandidate) -> Void) async {
        await inner.setLocalCandidateHandler(handler)
    }
    func setStateHandler(_ handler: @escaping @Sendable (CallMediaState) -> Void) async {
        await inner.setStateHandler(handler)
    }
    func setInterruptionHandler(_ handler: @escaping @Sendable (CallInterruption) -> Void) async {
        await inner.setInterruptionHandler(handler)
    }
    func setAudioStateHandler(_ handler: @escaping @Sendable (AudioState) -> Void) async {
        await inner.setAudioStateHandler(handler)
    }
    func selectAudioDevice(_ device: AudioDevice?) async { await inner.selectAudioDevice(device) }
    func setMuted(_ muted: Bool) async { await inner.setMuted(muted) }
    func close() async { await inner.close() }

    // Bridge capabilities

    func awaitIceGathering(quiet: TimeInterval, cap: TimeInterval) async {
        lock.lock(); _gatherWaits += 1; lock.unlock()
    }

    func localDescriptionSDP() async -> String? {
        lock.lock(); defer { lock.unlock() }; return gatheredSDP
    }

    func audioMid() async -> String? {
        lock.lock(); defer { lock.unlock() }; return mid
    }

    func acceptRemoteOffer(sdp: String) async throws -> String {
        lock.lock(); _acceptedOffers.append(sdp); let err = acceptRemoteOfferError; let answer = answerSDP; lock.unlock()
        if let err { throw err }
        return answer
    }

    func setRemoteAudioEnabled(_ enabled: Bool) async {
        lock.lock(); _remoteAudioEnabled.append(enabled); lock.unlock()
    }

    // Test drivers
    func driveState(_ state: CallMediaState) { inner.driveState(state) }
    func driveInterruption(_ interruption: CallInterruption) { inner.driveInterruption(interruption) }
    func driveAudioState(_ state: AudioState) { inner.driveAudioState(state) }
}
