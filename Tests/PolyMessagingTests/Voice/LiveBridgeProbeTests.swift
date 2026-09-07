// Copyright PolyAI Limited

import XCTest
@_spi(PolyVoice) @testable import PolyMessaging

/// Opt-in live integration probe: runs the **real** `BridgeApi` against a live
/// `webrtc-bridge` deployment and asserts the call-lifecycle contract the whole
/// pipeline is built on — provision mints a call, the per-call token gates every
/// route, and DELETE tears it down.
///
/// Skipped by default (it hits the network). Run with:
///
///     POLY_LIVE_VOICE=1 POLY_LIVE_VOICE_TOKEN=<web calling token> \
///       swift test --filter LiveBridgeProbeTests
///
/// Defaults to the dev cluster; override with `POLY_LIVE_VOICE_CLUSTER`.
///
/// No media follows (there's no WebRTC engine here), but every HTTP step before
/// the SDP exchange is exercised for real — which is what caught the shape of
/// the provision response the unit tests now assert against.
final class LiveBridgeProbeTests: XCTestCase {

    func test_liveBridge_provisionsAndDeletesACall() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["POLY_LIVE_VOICE"] == "1",
            "Set POLY_LIVE_VOICE=1 to run the live bridge probe"
        )
        let token = ProcessInfo.processInfo.environment["POLY_LIVE_VOICE_TOKEN"] ?? ""
        try XCTSkipIf(token.isEmpty, "Set POLY_LIVE_VOICE_TOKEN to the connector's web calling token")

        let cluster = ProcessInfo.processInfo.environment["POLY_LIVE_VOICE_CLUSTER"] ?? "dev"
        let logger = OSLogLogger(level: .error)
        let env = try BridgeEnvironment(environment: .cluster(cluster))
        let bridge = BridgeApi(baseURL: env.baseURL, authToken: token, logger: logger)

        let provision = try await bridge.provision()
        XCTAssertTrue(provision.callId.hasPrefix("call-"), "the bridge mints the call id")
        XCTAssertFalse(provision.credentials.connectPath.isEmpty)
        XCTAssertNotNil(provision.credentials.token, "a per-call token gates the remaining routes")
        XCTAssertNotNil(provision.credentials.eventsPath)
        XCTAssertNotNil(provision.credentials.pullPath)
        XCTAssertNotNil(provision.credentials.renegotiatePath)
        XCTAssertNotNil(bridge.eventsURL(provision)?.scheme.map { $0.hasPrefix("ws") })

        // Junk SDP with a valid call token must fail at the SFU, not at auth —
        // proof the X-Call-Token header is accepted where the contract says.
        do {
            _ = try await bridge.sendOffer(provision, sdp: "not-an-sdp", mid: "0")
            XCTFail("the bridge should reject an invalid offer")
        } catch let error as PolyError {
            XCTAssertFalse(
                "\(error)".contains("401"),
                "a valid per-call token must get past auth, got \(error)"
            )
        }

        await bridge.deleteCall(provision)
    }

    /// The credential contract, from the other side: no Bearer token, no call.
    func test_liveBridge_rejectsAnUnauthenticatedProvision() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["POLY_LIVE_VOICE"] == "1",
            "Set POLY_LIVE_VOICE=1 to run the live bridge probe"
        )
        let cluster = ProcessInfo.processInfo.environment["POLY_LIVE_VOICE_CLUSTER"] ?? "dev"
        let env = try BridgeEnvironment(environment: .cluster(cluster))
        let bridge = BridgeApi(baseURL: env.baseURL, authToken: "not-a-token", logger: OSLogLogger(level: .error))

        do {
            _ = try await bridge.provision()
            XCTFail("an invalid token must not provision a call")
        } catch let error as PolyError {
            XCTAssertTrue("\(error)".contains("401"), "expected a 401, got \(error)")
        }
    }
}
