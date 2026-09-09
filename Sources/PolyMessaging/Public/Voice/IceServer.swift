// Copyright PolyAI Limited

import Foundation

/// A STUN/TURN server the WebRTC peer connection uses for ICE.
///
/// Supplied by the bridge in its provision response per call (TURN relay
/// credentials are short-lived), then handed to the media engine. Falls back to
/// ``defaultServers`` when the response carries none, so a call can still
/// connect on open NATs.
public struct IceServer: Sendable, Equatable {
    public let urls: [String]
    public let username: String?
    public let credential: String?

    public init(urls: [String], username: String? = nil, credential: String? = nil) {
        self.urls = urls
        self.username = username
        self.credential = credential
    }

    /// STUN fallback when the bridge's provision response carries no ICE servers.
    ///
    /// Media terminates at Cloudflare's edge, so Cloudflare's own STUN endpoint is
    /// the supported one — the old `stun.l.google.com` default went out with the
    /// gateway. TURN relay (needed behind symmetric NAT / CGNAT) arrives in the
    /// provision response once the bridge sends one (RUN-1780).
    public static let defaultServers: [IceServer] = [
        IceServer(urls: ["stun:stun.cloudflare.com:3478"]),
    ]
}

extension IceServer {
    /// Parse the entries of an `iceServers` array as the bridge sends them:
    /// `[{ "urls": [...] | "urls": "...", "username"?, "credential"? }]`.
    static func parse(_ array: [[String: Any]]) -> [IceServer] {
        array.compactMap { obj in
            let urls: [String]
            if let list = obj["urls"] as? [String] {
                urls = list.filter { !$0.isEmpty }
            } else if let single = obj["urls"] as? String, !single.isEmpty {
                urls = [single]
            } else {
                urls = []
            }
            guard !urls.isEmpty else { return nil }
            let username = (obj["username"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let credential = (obj["credential"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return IceServer(urls: urls, username: username, credential: credential)
        }
    }
}
