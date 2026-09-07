// Copyright PolyAI Limited

import Foundation

/// State of the underlying media (WebRTC peer) connection.
public enum CallMediaState: Sendable, Equatable {
    case new
    case connecting
    case connected
    case disconnected
    case failed
    case closed
}

/// An audio-session interruption relevant to a live call (phone call, Siri, another app).
public enum CallInterruption: Sendable, Equatable {
    /// Audio was taken — mute the mic until the interruption ends.
    case began
    /// The interruption ended and the system says it's safe to resume — unmute.
    case endedResume
    /// The interruption ended but the system won't let us resume — end the call.
    case endedStop
}

/// The media (WebRTC peer-connection) seam that the call pipeline drives.
///
/// `PolyMessaging` is dependency-free and so ships no implementation: real
/// WebRTC audio needs a peer-connection engine (DTLS-SRTP / Opus) that a
/// zero-dependency package can't provide. `PolyVoice` supplies one, and this
/// protocol is `public` purely so it can do that across the module boundary.
///
/// > Important: This is an **SDK-internal seam, not a stable extension point.**
/// > It exists for `PolyVoice` (and for injecting a stub in the SDK's own
/// > tests). Conform to it outside the SDK at your own risk: capability
/// > methods will be added here in minor releases. Everything with a default
/// > implementation below is additive-safe; the core requirements are not.
@_spi(PolyVoice)
public protocol CallMediaEngine: Sendable {
    /// Acquire the microphone and produce the local SDP offer (audio), building
    /// the peer connection with the supplied ICE (STUN/TURN) servers.
    func createOffer(iceServers: [IceServer]) async throws -> String
    /// Apply the remote SDP answer returned by the gateway.
    func acceptAnswer(sdp: String) async throws
    /// Add a remote ICE candidate received from the gateway.
    func addRemoteCandidate(_ candidate: IceCandidate) async throws
    /// Register the sink for locally-gathered ICE candidates (forwarded to the
    /// gateway by the pipeline).
    func setLocalCandidateHandler(_ handler: @escaping @Sendable (IceCandidate) -> Void) async
    /// Register the sink for media connection-state transitions.
    func setStateHandler(_ handler: @escaping @Sendable (CallMediaState) -> Void) async
    /// Register the sink for audio-session interruptions (phone calls, Siri, etc.).
    func setInterruptionHandler(_ handler: @escaping @Sendable (CallInterruption) -> Void) async
    /// Register the sink for audio-routing snapshots (available outputs + the active one).
    func setAudioStateHandler(_ handler: @escaping @Sendable (AudioState) -> Void) async
    /// Route call audio to `device`, or `nil` to revert to automatic routing.
    func selectAudioDevice(_ device: AudioDevice?) async
    /// Mute / unmute the local microphone track.
    func setMuted(_ muted: Bool) async
    /// Tear down the peer connection and release the microphone.
    func close() async

    // MARK: - webrtc-bridge capabilities
    //
    // The bridge is non-trickle and renegotiates to start agent audio, so it
    // needs four things the gateway path never asked for. All are defaulted
    // below: an engine that doesn't implement them simply can't drive a bridge
    // call, and `BridgeCallCoordinator` reports that as a media failure rather
    // than placing a call that would silently carry no audio.

    /// Wait until ICE gathering has settled, so the offer POSTed to the bridge
    /// already carries its candidates (the SDP proxy has no candidate channel).
    ///
    /// Not keyed on `iceGatheringState == .complete`: a STUN transaction that
    /// never terminates pins that state at `.gathering` forever and suppresses
    /// the end-of-candidates signal with it. Implementations should treat a
    /// quiet candidate stream as settled and use `cap` only as a backstop.
    func awaitIceGathering(quiet: TimeInterval, cap: TimeInterval) async

    /// SDP of the current local description — read after ``awaitIceGathering(quiet:cap:)``
    /// to get the offer with its candidates in it.
    func localDescriptionSDP() async -> String?

    /// The `mid` of the microphone's audio transceiver, which tells the SFU
    /// which m-line carries the published track.
    func audioMid() async -> String?

    /// Apply a remote offer and return the answer (the bridge's agent-track
    /// renegotiation, which happens once on connect and again on every re-pull).
    func acceptRemoteOffer(sdp: String) async throws -> String

    /// Enable or disable playback of the received agent track. Used for
    /// barge-in: the SFU and jitter buffer already hold audio the client can't
    /// drop, so the track is muted the instant the bridge signals barge-in.
    func setRemoteAudioEnabled(_ enabled: Bool) async
}

// MARK: - Optional capabilities

/// Defaults for the requirements an engine can legitimately not implement, so
/// adding a capability here is additive rather than a source break for existing
/// conformers.
///
/// Deliberately NOT defaulted: `createOffer`, `acceptAnswer`, `addRemoteCandidate`,
/// `setLocalCandidateHandler`, `setStateHandler`, `setMuted` and `close`. A no-op
/// default on any of those would turn a missing implementation into a silently
/// broken call instead of a compile error — worse than the source break it avoids.
@_spi(PolyVoice)
public extension CallMediaEngine {
    /// Default: no interruption reporting (the call simply won't mute on a
    /// system interruption).
    func setInterruptionHandler(_ handler: @escaping @Sendable (CallInterruption) -> Void) async {}

    /// Default: no audio-routing snapshots (`PolyCall.audioState` stays empty).
    func setAudioStateHandler(_ handler: @escaping @Sendable (AudioState) -> Void) async {}

    /// Default: routing is left entirely to the system.
    func selectAudioDevice(_ device: AudioDevice?) async {}

    /// Default: nothing to wait for (a trickle-only engine has no gather phase
    /// the bridge could use).
    func awaitIceGathering(quiet: TimeInterval, cap: TimeInterval) async {}

    /// Default: the engine doesn't expose its local description, so the bridge
    /// path cannot read a gathered offer from it.
    func localDescriptionSDP() async -> String? { nil }

    /// Default: unknown mid — the bridge falls back to the first audio m-line.
    func audioMid() async -> String? { nil }

    /// Default: renegotiation unsupported. Surfaced as a media failure rather
    /// than a silent call with no agent audio.
    func acceptRemoteOffer(sdp: String) async throws -> String {
        throw PolyError.voice(.mediaFailed("this media engine cannot renegotiate"))
    }

    /// Default: no remote-track control (barge-in plays out its buffered tail).
    func setRemoteAudioEnabled(_ enabled: Bool) async {}
}
