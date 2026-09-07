// Copyright PolyAI Limited

import Foundation

/// Which WebRTC backend a call is placed through.
///
/// PolyAI is migrating voice from `webrtc-gateway` to `webrtc-bridge`
/// (RUN-1279). The two are not interchangeable at the protocol level — the
/// bridge provisions the call over HTTPS, mints the call id itself, sends SDP
/// non-trickle and runs a second negotiation for the agent's audio — so the SDK
/// ships both paths and this selects between them.
///
/// > Important: this is a **transitional** switch. `.gateway` stays the default
/// > while the bridge finishes its production rollout; once the gateway retires
/// > the bridge becomes the only path and this type is deprecated. Pin your app
/// > to `.gateway` explicitly only if you have a reason to — the migration is
/// > otherwise a version bump.
public enum VoiceTransport: String, Sendable, CaseIterable {
    /// `webrtc-gateway`: one signalling WebSocket, trickle ICE, and a call SID
    /// minted by this SDK. The default, and what every shipped app uses today.
    case gateway

    /// `webrtc-bridge`: the call is provisioned with `POST /api/v1/call`, SDP
    /// travels over HTTPS, the bridge mints the call id, and a control socket
    /// carries barge-in and re-pull. Media terminates at Cloudflare rather than
    /// at PolyAI.
    case bridge
}
