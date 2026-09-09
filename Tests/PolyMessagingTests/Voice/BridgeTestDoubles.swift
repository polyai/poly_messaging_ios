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
