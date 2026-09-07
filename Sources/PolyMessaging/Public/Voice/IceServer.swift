// Copyright PolyAI Limited

import Foundation

/// A STUN/TURN server the WebRTC peer connection uses for ICE.
///
/// Fetched from the gateway per call (TURN relay credentials are short-lived),
/// then handed to the media engine. Falls back to ``defaultServers`` (public STUN) when
/// the fetch fails so a call can still connect on open NATs.
public struct IceServer: Sendable, Equatable {
    public let urls: [String]
    public let username: String?
    public let credential: String?

    public init(urls: [String], username: String? = nil, credential: String? = nil) {
        self.urls = urls
        self.username = username
        self.credential = credential
    }

    /// Public STUN — the fallback when the gateway ICE fetch fails. TURN relay
    /// (needed to connect behind symmetric NAT / CGNAT) only comes from the gateway.
    public static let defaultServers: [IceServer] = [
        IceServer(urls: ["stun:stun.l.google.com:19302"]),
    ]

    /// STUN fallback for the `webrtc-bridge` path. Media terminates at
    /// Cloudflare's edge there, so Cloudflare's own STUN endpoint is the
    /// supported one — never the gateway's servers. Used only until the bridge
    /// returns an authoritative `iceServers` list in its provision response
    /// (RUN-1780), which will carry TURN for calls that need a relay.
    public static let bridgeDefaultServers: [IceServer] = [
        IceServer(urls: ["stun:stun.cloudflare.com:3478"]),
    ]
}
