// Copyright PolyAI Limited

import Foundation

/// Resolves the `webrtc-bridge` base URL for an ``Environment``.
///
/// Kept separate from ``VoiceEnvironment`` rather than folded into it: the
/// gateway path is shipped and carries production traffic, and the two services
/// don't share a host pattern in every cluster (see `plg-us-1-prod` below).
struct BridgeEnvironment: Sendable {

    /// `https://webrtc-bridge.<cluster>/` — every credentials path returned by
    /// the bridge resolves against this.
    let baseURL: URL

    /// - Parameter bridgeHost: overrides the derived host (self-hosted / a
    ///   port-forwarded bridge); **required** for `.custom`.
    init(environment: Environment, bridgeHost: String? = nil) throws {
        let host: String
        if let bridgeHost, !bridgeHost.isEmpty {
            host = bridgeHost
        } else {
            switch environment {
            case .us:  host = "webrtc-bridge.us-1.platform.polyai.app"
            case .uk:  host = "webrtc-bridge.uk-1.platform.polyai.app"
            case .euw: host = "webrtc-bridge.euw-1.platform.polyai.app"
            case .cluster(let name):
                host = Self.clusterHost(name)
            case .custom:
                throw PolyError.invalidConfiguration(
                    "The bridge on a .custom environment requires VoiceOptions.bridgeHost")
            }
        }
        // A trailing slash makes the base a directory, so a credentials path
        // resolves against the host rather than replacing the last path segment.
        guard let url = URL(string: "https://\(host)/") else {
            throw PolyError.invalidConfiguration("Invalid bridge host: \(host)")
        }
        baseURL = url
    }

    /// Cluster host rules, taken from the bridge's own gitops overlays:
    /// `dev` is standalone, `plg-us-1-prod` keeps its cluster name directly
    /// under `polyai.app`, and every other cluster sits under `.platform`.
    private static func clusterHost(_ name: String) -> String {
        switch name {
        case "dev": return "webrtc-bridge.dev.polyai.app"
        case "plg-us-1-prod": return "webrtc-bridge.plg-us-1-prod.polyai.app"
        default: return "webrtc-bridge.\(name).platform.polyai.app"
        }
    }
}
