// Copyright PolyAI Limited

import Foundation

/// Supplies the ICE (STUN/TURN) servers used to build a call's peer connection.
protocol IceServersProviding: Sendable {
    func fetch() async -> [IceServer]
}

/// Returns a fixed set — used by unit tests and as the STUN-only default.
struct StaticIceServersProvider: IceServersProviding {
    let servers: [IceServer]
    init(_ servers: [IceServer] = IceServer.defaultServers) { self.servers = servers }
    func fetch() async -> [IceServer] { servers }
}

/// Fetches ICE servers from the gateway (`GET /api/v1/ice-servers?token=…`),
/// authenticated with the web calling token. Best-effort: any failure — or
/// an empty list — falls back to public STUN so a call still connects on open
/// NATs.
struct GatewayIceServersFetcher: IceServersProviding {
    let url: URL?
    let logger: PolyLogger
    var urlSession: URLSession = .shared

    func fetch() async -> [IceServer] {
        guard let url else { return IceServer.defaultServers }
        do {
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                logger.warn("ICE servers fetch returned non-2xx; falling back to STUN", metadata: nil)
                return IceServer.defaultServers
            }
            let parsed = Self.parse(data)
            return parsed.isEmpty ? IceServer.defaultServers : parsed
        } catch {
            logger.warn("ICE servers fetch failed; falling back to STUN", metadata: ["error": error.localizedDescription])
            return IceServer.defaultServers
        }
    }

    /// Parse `{ "iceServers": [ { "urls": [...] | "url", "username"?, "credential"? } ] }`.
    static func parse(_ data: Data) -> [IceServer] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let array = json["iceServers"] as? [[String: Any]] else {
            return []
        }
        return parseServers(array)
    }

    /// Parse the entries of an `iceServers` array. Shared with the bridge, whose
    /// provision response carries the same objects inline rather than behind a
    /// dedicated endpoint.
    static func parseServers(_ array: [[String: Any]]) -> [IceServer] {
        return array.compactMap { obj in
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
