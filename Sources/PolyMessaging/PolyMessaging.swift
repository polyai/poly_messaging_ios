// Copyright PolyAI Limited

import Foundation

public enum PolyMessaging {

    private static let resumeWindowSeconds: TimeInterval = 600
    private static let configLock = NSLock()
    private static var _config: Configuration?

    public static func initialize(_ config: Configuration) {
        guard !config.apiKey.isEmpty else {
            fatalError("PolyMessaging: apiKey must not be empty. Get your connector token from Agent Studio.")
        }
        configLock.lock()
        _config = config
        configLock.unlock()
    }

    /// SPI seam so `PolyVoice.call(options:)` can default to the `Configuration` set by
    /// `initialize(_:)` — the same crash-early contract as `chat()` / `voice()`: calling
    /// before `initialize(_:)` is a programmer error, not a recoverable one.
    @_spi(PolyVoice)
    public static var currentConfig: Configuration {
        configLock.lock()
        let config = _config
        configLock.unlock()
        guard let config else {
            fatalError("PolyMessaging: call initialize(_:) in application(_:didFinishLaunching:) before using the SDK")
        }
        return config
    }

    @discardableResult
    public static func configure(_ config: Configuration) throws -> PolyMessagingClient {
        guard !config.apiKey.isEmpty else {
            throw PolyError.invalidConfiguration("apiKey must not be empty")
        }
        return PolyMessagingClient(config: config)
    }

    private static func makeClient(_ config: Configuration) -> PolyMessagingClient {
        guard !config.apiKey.isEmpty else {
            fatalError("PolyMessaging: apiKey must not be empty. Get your connector token from Agent Studio.")
        }
        return PolyMessagingClient(config: config)
    }

    public static func hasResumableSession(apiKey: String) -> Bool {
        guard !apiKey.isEmpty else { return false }
        let store = SessionStore(apiKey: apiKey)
        guard let stored = store.load() else { return false }
        guard Date().timeIntervalSince(stored.timestamp) < resumeWindowSeconds else { return false }
        guard let token = stored.accessToken else { return false }
        return JWTValidator.isStructurallyValid(token)
    }

    public static func clearResumableSession(apiKey: String) {
        guard !apiKey.isEmpty else { return }
        SessionStore(apiKey: apiKey).clear()
    }

    public static func hasResumableSession() -> Bool {
        hasResumableSession(apiKey: currentConfig.apiKey)
    }

    public static func clearResumableSession() {
        clearResumableSession(apiKey: currentConfig.apiKey)
    }

    // MARK: - One-shot API

    @MainActor
    public static func chat(streamingEnabled: Bool? = nil) -> ChatSession {
        chat(currentConfig, streamingEnabled: streamingEnabled)
    }

    @MainActor
    public static func chat(_ config: Configuration, streamingEnabled: Bool? = nil) -> ChatSession {
        let client = makeClient(config)
        return ChatSession(client: client, streamingEnabled: streamingEnabled)
    }

    @MainActor
    public static func start(streamingEnabled: Bool? = nil) -> ChatSession {
        start(currentConfig, streamingEnabled: streamingEnabled)
    }

    @MainActor
    public static func start(_ config: Configuration, streamingEnabled: Bool? = nil) -> ChatSession {
        clearResumableSession(apiKey: config.apiKey)
        let client = makeClient(config)
        return ChatSession(client: client, streamingEnabled: streamingEnabled)
    }

    @available(*, deprecated, renamed: "chat")
    @MainActor
    public static func resume(_ config: Configuration, streamingEnabled: Bool? = nil) -> ChatSession {
        chat(config, streamingEnabled: streamingEnabled)
    }

    // MARK: - Voice

    @MainActor
    public static func voice() -> PolyCall {
        voice(currentConfig)
    }

    @MainActor
    public static func voice(_ config: Configuration) -> PolyCall {
        PolyCall(config: config)
    }
}
