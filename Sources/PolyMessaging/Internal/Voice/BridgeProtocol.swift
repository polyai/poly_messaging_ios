// Copyright PolyAI Limited

import Foundation

/// Wire types and framing for `webrtc-bridge` (RUN-1117 / RUN-1279), the
/// replacement for `webrtc-gateway`.
///
/// Unlike the gateway — one WebSocket carrying auth, SDP and trickle ICE — the
/// bridge splits the call across HTTPS and a control socket:
///
///   1. `POST /api/v1/call` (`Authorization: Bearer <webrtcToken>`) mints the
///      call and returns `callId` plus short-lived per-call credentials.
///   2. Every subsequent HTTP route carries that per-call token in
///      `X-Call-Token` — never in a URL (RUN-1692).
///   3. SDP travels as JSON over HTTPS (`/sdp`, `/sdp/pull`, `/sdp/renegotiate`),
///      non-trickle: the offer must already carry its candidates.
///   4. The events WebSocket cannot set a header on its upgrade, so it sends
///      the same token as its first frame instead.
///
/// Pure and stateless — the transport lives in ``BridgeApi``.
enum BridgeProtocol {

    /// HTTP header carrying the per-call token on every route after provision.
    static let callTokenHeader = "X-Call-Token"

    /// The only mode a customer-facing call uses. The bridge defaults to
    /// `"echo"`, which authenticated deployments reject with a 403.
    static let voiceAgentMode = "voice-agent"

    // MARK: - Provision

    /// Body for `POST /api/v1/call`. Account, project and client environment are
    /// derived server-side from the verified token, so the body carries only what
    /// the token cannot: the mode, and (unused on mobile) the caller label.
    static func provisionBody(mode: String = voiceAgentMode) -> Data? {
        try? JSONSerialization.data(withJSONObject: ["mode": mode])
    }

    /// Parsed `POST /api/v1/call` response.
    struct Provision: Sendable, Equatable {
        let callId: String
        let credentials: Credentials
    }

    /// The per-call credentials the bridge returns. Every URL is a **path**,
    /// resolved against the bridge's base URL by ``BridgeApi``.
    struct Credentials: Sendable, Equatable {
        let provider: String
        let connectPath: String
        let token: String?
        let trackName: String?
        /// ICE servers the bridge wants this call to use. The dev deployment does
        /// not send these yet (RUN-1780), so callers fall back to
        /// ``IceServer/defaultServers``.
        let iceServers: [IceServer]
        let eventsPath: String?
        let pullPath: String?
        let renegotiatePath: String?
    }

    /// Parse the provision response. Returns nil when the payload is missing the
    /// two fields a call cannot proceed without (`callId` and `creds.connectUrl`).
    static func parseProvision(_ data: Data) -> Provision? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? WireJSON,
              let callId = json.string("callId"), !callId.isEmpty,
              let creds = json.dict("creds"),
              let connect = creds.string("connectUrl"), !connect.isEmpty else {
            return nil
        }
        let extra = creds.dict("extra") ?? [:]
        return Provision(
            callId: callId,
            credentials: Credentials(
                provider: creds.string("provider") ?? "",
                connectPath: connect,
                token: creds.string("token"),
                trackName: creds.string("trackName"),
                iceServers: IceServer.parse(creds.array("iceServers") ?? []),
                eventsPath: extra.string("eventsUrl"),
                pullPath: extra.string("pullUrl"),
                renegotiatePath: extra.string("renegotiateUrl")
            )
        )
    }

    // MARK: - SDP exchange

    /// Body for `POST {connectUrl}`: the gathered offer plus the microphone
    /// transceiver's mid, which tells Cloudflare which m-line we publish.
    static func offerBody(sdp: String, mid: String) -> Data? {
        try? JSONSerialization.data(withJSONObject: ["sdp": sdp, "mid": mid])
    }

    /// Body for `POST {renegotiateUrl}`: the answer to the pull's offer.
    static func sdpBody(_ sdp: String) -> Data? {
        try? JSONSerialization.data(withJSONObject: ["sdp": sdp])
    }

    /// Both `/sdp` (answer) and `/sdp/pull` (renegotiation offer) reply with the
    /// same one-field shape.
    static func parseSDP(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? WireJSON,
              let sdp = json.string("sdp"), !sdp.isEmpty else {
            return nil
        }
        return sdp
    }

    // MARK: - Events socket

    /// The first frame the events socket must send. A WebSocket upgrade can't
    /// carry `X-Call-Token`, so the token rides here; the bridge closes the
    /// socket (policy violation) on anything else.
    static func eventsAuthFrame(token: String) -> Data? {
        try? JSONSerialization.data(withJSONObject: ["type": "auth", "token": token])
    }

    /// A control message from the bridge's events socket.
    enum Event: Sendable, Equatable {
        /// The agent's track was republished into a new Cloudflare session — the
        /// existing subscription has gone silent and must be pulled again.
        case repull
        /// Barge-in fired server-side: silence the agent immediately rather than
        /// play out what the SFU and jitter buffer already hold.
        case bargeIn
        /// The agent resumed after a barge-in.
        case unmute
    }

    /// Parse an inbound events frame. Unknown frames are ignored (nil).
    static func parseEvent(_ data: Data) -> Event? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? WireJSON,
              let event = json.string("event") else {
            return nil
        }
        switch event {
        case "repull": return .repull
        case "unmute": return .unmute
        default:
            // Barge-in arrives as a family of `barge-in*` events; they all mean
            // "silence the agent now".
            return event.hasPrefix("barge-in") ? .bargeIn : nil
        }
    }
}
