// Copyright PolyAI Limited

import Foundation
import PolyMessaging

/// Options for ``PolyVoice/call(config:options:)``.
///
/// `webrtcToken` is **required** — every voice call needs the web calling
/// token, a distinct value from the connector token (both come from Agent
/// Studio › Connector Settings).
///
/// > Note: calls are placed over `webrtc-bridge`. The retired `webrtc-gateway`
/// > path is gone (MES-1658), but this type is unchanged — the same options
/// > mean the same things.
public struct VoiceOptions: Sendable {

    /// The connector's web calling token — the Bearer credential the bridge
    /// provisions a call against. Always distinct from `Configuration.apiKey`.
    public let webrtcToken: String

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
        webrtcToken: String,
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
