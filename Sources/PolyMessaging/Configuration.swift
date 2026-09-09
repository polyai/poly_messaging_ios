// Copyright PolyAI Limited

import Foundation

public struct Configuration: Sendable {
    public let apiKey: String
    public let environment: Environment
    /// When nil, defaults to the app's bundle identifier (e.g. `com.yourcompany.app`).
    /// Must match the host domain registered in Agent Studio when generating the connector token.
    public let hostIdentifier: String?
    public let streamingEnabled: Bool
    public let logLevel: LogLevel
    /// Override the default heartbeat interval (30s). Server `SessionCapabilities`
    /// still overrides this once the session is established.
    public let heartbeatIntervalSeconds: Int?
    /// Override the default session idle timeout (600s = 10 min). Mirrors the
    /// backend's WebSocket idle timeout — sessions still alive on the server
    /// can be resumed within this window; older ones are gone.
    public let sessionTimeoutSeconds: Int?
    /// Override the default max-reconnect attempts (10). Server `SessionCapabilities`
    /// still overrides this once the session is established.
    public let maxReconnectAttempts: Int?
    /// The connector's web calling token (PolyVoice) — set it here, once, alongside
    /// `apiKey`, so it doesn't need repeating at every `PolyVoice.call(...)` site.
    /// `VoiceOptions.webrtcToken` still wins when both are set. Chat-only apps
    /// leave this `nil`; `PolyMessaging` itself never reads it.
    public let webrtcToken: String?
    public init(
        apiKey: String,
        environment: Environment = .us,
        hostIdentifier: String? = nil,
        streamingEnabled: Bool = true,
        logLevel: LogLevel = .error,
        heartbeatIntervalSeconds: Int? = nil,
        sessionTimeoutSeconds: Int? = nil,
        maxReconnectAttempts: Int? = nil,
        webrtcToken: String? = nil
    ) {
        self.apiKey = apiKey
        self.environment = environment
        self.hostIdentifier = hostIdentifier
        self.streamingEnabled = streamingEnabled
        self.logLevel = logLevel
        self.heartbeatIntervalSeconds = heartbeatIntervalSeconds
        self.sessionTimeoutSeconds = sessionTimeoutSeconds
        self.maxReconnectAttempts = maxReconnectAttempts
        self.webrtcToken = webrtcToken
    }
}

#if false
public enum CertificatePinning: Sendable, Equatable {
    case none
    case spki(sha256Hashes: Set<Data>)
    case certificate(sha256Hashes: Set<Data>)
}
#endif

public enum Environment: Sendable {
    /// Production US region (`messaging.us-1.poly.ai`). The default — most apps want this.
    case us
    /// Production UK region (`messaging.uk-1.poly.ai`).
    case uk
    /// Production EU West region (`messaging.euw-1.poly.ai`).
    case euw
    /// Override both base URLs entirely — for local mocks, proxies, or one-off deployments.
    case custom(restBaseURL: URL, wsBaseURL: URL)
    /// Escape hatch for any named cluster not covered above, e.g. `.cluster("dev")`
    /// (resolves to `messaging.dev.poly.ai`) or a staging cluster.
    case cluster(String)
}

public enum Platform: String, Sendable {
    case ios
}

public enum LogLevel: Int, Sendable, Comparable {
    case none = 0
    case error = 1
    case warn = 2
    case info = 3
    case debug = 4

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
