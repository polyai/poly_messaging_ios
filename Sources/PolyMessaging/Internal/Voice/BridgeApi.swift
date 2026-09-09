// Copyright PolyAI Limited

import Foundation

/// The bridge's HTTPS surface: provision a call, exchange SDP, and tear it down.
/// Every route after provision authenticates with the per-call token in
/// `X-Call-Token`.
///
/// A port rather than a concrete type so the call pipeline can be driven against
/// a fake in unit tests, exactly like ``RestApiPort`` and ``SignalingChannel``.
protocol BridgeApiPort: Sendable {
    /// `POST /api/v1/call` with the web calling token as a Bearer credential.
    func provision() async throws -> BridgeProtocol.Provision
    /// `POST {connectUrl}` — the gathered offer; returns the answer SDP.
    func sendOffer(_ provision: BridgeProtocol.Provision, sdp: String, mid: String) async throws -> String
    /// `POST {pullUrl}` — subscribe to the agent track; returns a renegotiation offer SDP.
    func pullAgentTrack(_ provision: BridgeProtocol.Provision) async throws -> String
    /// `POST {renegotiateUrl}` — the answer to the pull's offer.
    func renegotiate(_ provision: BridgeProtocol.Provision, answerSdp: String) async throws -> Void
    /// `DELETE /api/v1/call/{callId}` — best-effort teardown.
    func deleteCall(_ provision: BridgeProtocol.Provision) async
    /// Absolute URL of the events socket, or nil when the bridge didn't offer one.
    func eventsURL(_ provision: BridgeProtocol.Provision) -> URL?
}

/// `URLSession`-backed ``BridgeApiPort``.
struct BridgeApi: BridgeApiPort {

    let baseURL: URL
    /// The connector's web calling token — the Bearer credential on provision.
    /// The bridge resolves account, project and client environment from it, so
    /// nothing else identifies the caller.
    let authToken: String
    let logger: PolyLogger
    var urlSession: URLSession = .shared
    /// Provision is the only route on the critical path with no fallback, so it
    /// gets its own deadline rather than URLSession's 60s default.
    var timeout: TimeInterval = 15

    func provision() async throws -> BridgeProtocol.Provision {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/call"), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = BridgeProtocol.provisionBody()

        let data = try await send(request, route: "provision")
        guard let provision = BridgeProtocol.parseProvision(data) else {
            throw PolyError.voice(.signalingFailed("Bridge returned an unreadable provision response"))
        }
        logger.debug("Bridge call provisioned", metadata: [
            "callId": provision.callId,
            "provider": provision.credentials.provider,
        ])
        return provision
    }

    func sendOffer(_ provision: BridgeProtocol.Provision, sdp: String, mid: String) async throws -> String {
        var request = try callRequest(provision, path: provision.credentials.connectPath, route: "sdp")
        request.httpBody = BridgeProtocol.offerBody(sdp: sdp, mid: mid)
        let data = try await send(request, route: "sdp")
        guard let answer = BridgeProtocol.parseSDP(data) else {
            throw PolyError.voice(.signalingFailed("Bridge returned no answer SDP"))
        }
        return answer
    }

    func pullAgentTrack(_ provision: BridgeProtocol.Provision) async throws -> String {
        guard let path = provision.credentials.pullPath else {
            throw PolyError.voice(.signalingFailed("Bridge offered no agent-track pull URL"))
        }
        var request = try callRequest(provision, path: path, route: "pull")
        request.httpBody = Data("{}".utf8)
        let data = try await send(request, route: "pull")
        guard let offer = BridgeProtocol.parseSDP(data) else {
            throw PolyError.voice(.signalingFailed("Bridge returned no renegotiation offer"))
        }
        return offer
    }

    func renegotiate(_ provision: BridgeProtocol.Provision, answerSdp: String) async throws {
        guard let path = provision.credentials.renegotiatePath else {
            throw PolyError.voice(.signalingFailed("Bridge offered no renegotiate URL"))
        }
        var request = try callRequest(provision, path: path, route: "renegotiate")
        request.httpBody = BridgeProtocol.sdpBody(answerSdp)
        _ = try await send(request, route: "renegotiate")
    }

    func deleteCall(_ provision: BridgeProtocol.Provision) async {
        guard let url = resolve("/api/v1/call/\(provision.callId)") else { return }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "DELETE"
        if let token = provision.credentials.token {
            request.setValue(token, forHTTPHeaderField: BridgeProtocol.callTokenHeader)
        }
        // Best-effort: the bridge also reaps a session when its events socket
        // drops, so a lost DELETE is not a leak.
        _ = try? await send(request, route: "delete")
    }

    func eventsURL(_ provision: BridgeProtocol.Provision) -> URL? {
        guard let path = provision.credentials.eventsPath, let url = resolve(path) else { return nil }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = (components.scheme == "http") ? "ws" : "wss"
        return components.url
    }

    // MARK: - Internal

    /// Resolve a credentials path against the bridge base URL. The bridge returns
    /// paths, not absolute URLs, so they must never be resolved against anything
    /// else.
    private func resolve(_ path: String) -> URL? {
        URL(string: path, relativeTo: baseURL)?.absoluteURL
    }

    private func callRequest(
        _ provision: BridgeProtocol.Provision,
        path: String,
        route: String
    ) throws -> URLRequest {
        guard let url = resolve(path) else {
            throw PolyError.voice(.signalingFailed("Bridge returned an unusable \(route) URL"))
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = provision.credentials.token {
            request.setValue(token, forHTTPHeaderField: BridgeProtocol.callTokenHeader)
        }
        return request
    }

    private func send(_ request: URLRequest, route: String) async throws -> Data {
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw PolyError.voice(.signalingFailed("Bridge \(route): no HTTP response"))
            }
            guard (200..<300).contains(http.statusCode) else {
                // 401 is the one status worth naming: it means the token was
                // rejected, not that the network failed.
                if http.statusCode == 401 {
                    throw PolyError.voice(.signalingFailed("Bridge \(route) rejected the call credentials (401)"))
                }
                throw PolyError.voice(.signalingFailed("Bridge \(route) failed (\(http.statusCode))"))
            }
            return data
        } catch let error as PolyError {
            throw error
        } catch {
            throw PolyError.voice(.signalingFailed("Bridge \(route) request failed: \(error.localizedDescription)"))
        }
    }
}
