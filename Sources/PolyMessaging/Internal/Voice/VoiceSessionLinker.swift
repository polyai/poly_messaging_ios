// Copyright PolyAI Limited

import Foundation

/// Opens the messaging WebSocket for a voice call and links it to the WebRTC
/// call by sending `EVENT_TYPE_LINK_TO_WEBRTC_CONVERSATION` once the session
/// starts. Manages the messaging WebSocket used alongside voice calls.
///
/// The `call_sid` it carries is the id the **bridge** minted, so this can only
/// run after the call is provisioned.
///
/// Reuses the existing `Connection` transport: the voice call rides on a normal
/// messaging session (so the agent's transcript/events flow over the same
/// pipe), with the bridge's call id correlating it to the audio leg.
actor VoiceSessionLinker {

    private let connection: Connection
    private let wsBaseURL: URL
    private let logger: PolyLogger

    init(connection: Connection, wsBaseURL: URL, logger: PolyLogger) {
        self.connection = connection
        self.wsBaseURL = wsBaseURL
        self.logger = logger
    }

    /// Open the WS and resolve once `SESSION_START` is received and the link
    /// frame has been sent. Throws on timeout.
    func open(
        accessToken: String,
        sessionId: String,
        callSid: String,
        timeout: TimeInterval = 15
    ) async throws {
        guard var comps = URLComponents(url: wsBaseURL, resolvingAgainstBaseURL: false) else {
            throw PolyError.voice(.signalingFailed("Invalid voice WS base URL"))
        }
        // Append to any query the base URL already carries (a `.custom` ws URL may
        // have its own parameters) instead of replacing it.
        comps.queryItems = (comps.queryItems ?? []) + [
            URLQueryItem(name: "access_token", value: accessToken),
            URLQueryItem(name: "session_id", value: sessionId),
        ]
        guard let url = comps.url else {
            throw PolyError.voice(.signalingFailed("Invalid voice WS URL"))
        }

        // Subscribe before connecting so the SESSION_START frame isn't missed.
        let messages = connection.messages
        await connection.connect(url: url)

        let started = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await event in messages {
                    if case .sessionStart = event { return true }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }

        guard started else {
            throw PolyError.voice(.timedOut)
        }

        let frame: [String: Any] = [
            "type": "EVENT_TYPE_LINK_TO_WEBRTC_CONVERSATION",
            "payload": ["call_sid": callSid],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: frame) {
            // Voice linking is opportunistic — if the transport is in the
            // brief reconnect window the caller will surface a higher-level
            // voice failure if needed. We log and move on.
            do {
                try await connection.sendRaw(data)
                logger.debug("Linked voice session to WebRTC call", metadata: ["callSid": callSid])
            } catch {
                logger.warn("Voice link send failed", metadata: ["error": String(describing: error)])
            }
        }
    }

    func close() async {
        await connection.disconnect(code: 1000, reason: "")
    }
}
