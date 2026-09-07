// Copyright PolyAI Limited

import XCTest
@_spi(PolyVoice) @testable import PolyMessaging

/// Wire-level tests for the `webrtc-bridge` protocol. The provision payload used
/// here is a verbatim capture from the dev deployment
/// (`webrtc-bridge.dev.polyai.app`), so a server-side shape change breaks these
/// rather than a live call.
final class BridgeProtocolTests: XCTestCase {

    private let liveProvisionJSON = """
    {"callId":"call-5f9ec645","creds":{"provider":"cloudflare",\
    "connectUrl":"/api/v1/call/call-5f9ec645/sdp",\
    "token":"1788794409.CSOgLZEbgQ9bloJ0EE7zk8KHVNSTpogvB_sEaIzGtCA",\
    "trackName":"agent-echo","extra":{\
    "eventsUrl":"/api/v1/call/call-5f9ec645/events",\
    "pullUrl":"/api/v1/call/call-5f9ec645/sdp/pull",\
    "renegotiateUrl":"/api/v1/call/call-5f9ec645/sdp/renegotiate"}}}
    """

    // MARK: - Provision

    func test_parseProvision_readsLiveDevResponse() throws {
        let provision = try XCTUnwrap(BridgeProtocol.parseProvision(Data(liveProvisionJSON.utf8)))

        XCTAssertEqual(provision.callId, "call-5f9ec645")
        XCTAssertEqual(provision.credentials.provider, "cloudflare")
        XCTAssertEqual(provision.credentials.connectPath, "/api/v1/call/call-5f9ec645/sdp")
        XCTAssertEqual(provision.credentials.trackName, "agent-echo")
        XCTAssertEqual(provision.credentials.pullPath, "/api/v1/call/call-5f9ec645/sdp/pull")
        XCTAssertEqual(provision.credentials.renegotiatePath, "/api/v1/call/call-5f9ec645/sdp/renegotiate")
        XCTAssertEqual(provision.credentials.eventsPath, "/api/v1/call/call-5f9ec645/events")
        XCTAssertTrue(provision.credentials.token?.hasPrefix("1788794409.") == true)
    }

    /// The dev bridge sends no `iceServers` yet (RUN-1780). Absence must leave
    /// the list empty so the coordinator falls back to Cloudflare STUN, rather
    /// than producing a bogus entry.
    func test_parseProvision_missingIceServers_yieldsEmptyList() throws {
        let provision = try XCTUnwrap(BridgeProtocol.parseProvision(Data(liveProvisionJSON.utf8)))
        XCTAssertTrue(provision.credentials.iceServers.isEmpty)
    }

    func test_parseProvision_readsIceServersWhenPresent() throws {
        let json = """
        {"callId":"call-1","creds":{"provider":"cloudflare","connectUrl":"/sdp",
        "iceServers":[{"urls":["turn:turn.example:3478"],"username":"u","credential":"c"}]}}
        """
        let provision = try XCTUnwrap(BridgeProtocol.parseProvision(Data(json.utf8)))
        XCTAssertEqual(provision.credentials.iceServers, [
            IceServer(urls: ["turn:turn.example:3478"], username: "u", credential: "c"),
        ])
    }

    func test_parseProvision_rejectsPayloadsMissingTheEssentials() {
        XCTAssertNil(BridgeProtocol.parseProvision(Data("{}".utf8)))
        XCTAssertNil(BridgeProtocol.parseProvision(Data(#"{"callId":"call-1"}"#.utf8)))
        XCTAssertNil(BridgeProtocol.parseProvision(Data(#"{"callId":"","creds":{"connectUrl":"/sdp"}}"#.utf8)))
        XCTAssertNil(BridgeProtocol.parseProvision(Data(#"{"callId":"c","creds":{"connectUrl":""}}"#.utf8)))
        XCTAssertNil(BridgeProtocol.parseProvision(Data("not json".utf8)))
    }

    /// `mode` must be `voice-agent`: the bridge defaults to `echo`, which
    /// authenticated deployments reject with a 403.
    func test_provisionBody_requestsVoiceAgentMode() throws {
        let body = try XCTUnwrap(BridgeProtocol.provisionBody())
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["mode"] as? String, "voice-agent")
        // No caller: a mobile call has no signed-in user to attribute it to.
        XCTAssertNil(json["caller"])
    }

    // MARK: - SDP

    func test_offerBody_carriesSdpAndMid() throws {
        let body = try XCTUnwrap(BridgeProtocol.offerBody(sdp: "v=0\r\noffer", mid: "0"))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["sdp"] as? String, "v=0\r\noffer")
        XCTAssertEqual(json["mid"] as? String, "0")
    }

    func test_parseSDP_readsAnswerAndRejectsEmpty() {
        XCTAssertEqual(BridgeProtocol.parseSDP(Data(#"{"sdp":"v=0\r\nanswer"}"#.utf8)), "v=0\r\nanswer")
        XCTAssertNil(BridgeProtocol.parseSDP(Data(#"{"sdp":""}"#.utf8)))
        XCTAssertNil(BridgeProtocol.parseSDP(Data("{}".utf8)))
        XCTAssertNil(BridgeProtocol.parseSDP(Data("".utf8)))
    }

    // MARK: - Events socket

    func test_eventsAuthFrame_matchesTheServersExpectedShape() throws {
        let frame = try XCTUnwrap(BridgeProtocol.eventsAuthFrame(token: "tok"))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: frame) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "auth")
        XCTAssertEqual(json["token"] as? String, "tok")
    }

    func test_parseEvent_mapsControlFrames() {
        XCTAssertEqual(BridgeProtocol.parseEvent(Data(#"{"event":"repull"}"#.utf8)), .repull)
        XCTAssertEqual(BridgeProtocol.parseEvent(Data(#"{"event":"unmute"}"#.utf8)), .unmute)
        XCTAssertEqual(BridgeProtocol.parseEvent(Data(#"{"event":"barge-in"}"#.utf8)), .bargeIn)
        // The whole `barge-in*` family means "silence the agent now".
        XCTAssertEqual(BridgeProtocol.parseEvent(Data(#"{"event":"barge-in-detected"}"#.utf8)), .bargeIn)
    }

    func test_parseEvent_ignoresUnknownAndMalformedFrames() {
        XCTAssertNil(BridgeProtocol.parseEvent(Data(#"{"event":"something-new"}"#.utf8)))
        XCTAssertNil(BridgeProtocol.parseEvent(Data(#"{"type":"stats"}"#.utf8)))
        XCTAssertNil(BridgeProtocol.parseEvent(Data("not json".utf8)))
    }

    // MARK: - Host resolution

    /// Hosts are taken from the bridge's own gitops overlays; `plg-us-1-prod` is
    /// the one cluster that doesn't sit under `.platform`.
    func test_bridgeEnvironment_resolvesClusterHosts() throws {
        XCTAssertEqual(
            try BridgeEnvironment(environment: .us).baseURL.absoluteString,
            "https://webrtc-bridge.us-1.platform.polyai.app/"
        )
        XCTAssertEqual(
            try BridgeEnvironment(environment: .uk).baseURL.absoluteString,
            "https://webrtc-bridge.uk-1.platform.polyai.app/"
        )
        XCTAssertEqual(
            try BridgeEnvironment(environment: .euw).baseURL.absoluteString,
            "https://webrtc-bridge.euw-1.platform.polyai.app/"
        )
        XCTAssertEqual(
            try BridgeEnvironment(environment: .cluster("dev")).baseURL.absoluteString,
            "https://webrtc-bridge.dev.polyai.app/"
        )
        XCTAssertEqual(
            try BridgeEnvironment(environment: .cluster("plg-us-1-prod")).baseURL.absoluteString,
            "https://webrtc-bridge.plg-us-1-prod.polyai.app/"
        )
    }

    func test_bridgeEnvironment_customRequiresAnExplicitHost() {
        XCTAssertThrowsError(
            try BridgeEnvironment(environment: .custom(
                restBaseURL: URL(string: "https://api.test")!,
                wsBaseURL: URL(string: "wss://api.test/ws")!
            ))
        )
    }

    func test_bridgeEnvironment_hostOverrideWins() throws {
        let env = try BridgeEnvironment(environment: .us, bridgeHost: "localhost:8080")
        XCTAssertEqual(env.baseURL.absoluteString, "https://localhost:8080/")
    }

    /// Credentials paths must resolve against the bridge host, not replace the
    /// last path component of it.
    func test_credentialsPathsResolveAgainstTheBridgeBase() throws {
        let base = try BridgeEnvironment(environment: .cluster("dev")).baseURL
        let resolved = URL(string: "/api/v1/call/call-1/sdp", relativeTo: base)?.absoluteString
        XCTAssertEqual(resolved, "https://webrtc-bridge.dev.polyai.app/api/v1/call/call-1/sdp")
    }
}
