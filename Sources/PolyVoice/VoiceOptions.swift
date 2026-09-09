// Copyright PolyAI Limited

import Foundation
import PolyMessaging

/// Options for ``PolyVoice/call(config:options:)``.
///
/// A web calling token is **required** — every voice call needs it, a distinct
/// value from the connector token (both come from Agent Studio › Connector
/// Settings) — but it doesn't have to be set here: leave `webrtcToken` `nil`
/// to fall back to `Configuration.webrtcToken`, so an app that sets both
/// tokens once on `Configuration` at launch never repeats the web calling
/// token at a `PolyVoice.call(...)` site.
///
/// > Note: calls are placed over `webrtc-bridge`. The retired `webrtc-gateway`
/// > path is gone (MES-1658); the remaining options still control audio routing,
/// > custom hosts, and CallKit integration.
public struct VoiceOptions: Sendable {

    /// The connector's web calling token — the Bearer credential the bridge
    /// provisions a call against. Always distinct from `Configuration.apiKey`.
    /// `nil` falls back to `Configuration.webrtcToken`; `PolyVoice.call(...)`
    /// throws `PolyError.invalidConfiguration` if neither is set.
    public let webrtcToken: String?

    /// The fallback route when no headset/Bluetooth is connected: the loudspeaker
    /// (hands-free, the `true` default) or the earpiece (`false`). A connected
    /// accessory is always preferred automatically.
    public let speakerphone: Bool

    /// Override the media host — the `webrtc-bridge` deployment a call is placed
    /// through (e.g. a self-hosted, dev or port-forwarded bridge). When nil the
    /// host is derived from `Configuration.environment`. **Required** when the
    /// environment is `.custom`.
    public let signalingHost: String?

    /// Set `true` when the app drives this call through **CallKit** (`CXProvider`).
    ///
    /// The SDK then never activates or deactivates the audio session itself and
    /// defers the WebRTC audio unit to CallKit — the app **must** forward the
    /// three `CXProviderDelegate` moments:
    /// `PolyVoice.callKitConfigureAudioSession()` from `perform(CXStartCallAction)`,
    /// `PolyVoice.callKitAudioSessionDidActivate(_:)` from `provider(_:didActivate:)`,
    /// and `PolyVoice.callKitAudioSessionDidDeactivate(_:)` from `provider(_:didDeactivate:)`.
    /// Without those calls the call connects but carries no audio.
    /// System interruptions (a cellular call, Siri) are also left to CallKit's
    /// hold/deactivate callbacks instead of the SDK's own interruption handling.
    /// See the `02-CallKit` Voice example.
    public let callKit: Bool

    public init(
        webrtcToken: String? = nil,
        speakerphone: Bool = true,
        signalingHost: String? = nil,
        callKit: Bool = false
    ) {
        self.webrtcToken = webrtcToken
        self.speakerphone = speakerphone
        self.signalingHost = signalingHost
        self.callKit = callKit
    }
}
