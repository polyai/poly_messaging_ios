// Copyright PolyAI Limited

#if os(iOS)
import Foundation
import WebRTC
@_spi(PolyVoice) import PolyMessaging

/// Real WebRTC audio engine.
///
/// Audio-only (Opus), Unified Plan, **non-trickle** ICE — the bridge takes a
/// fully-gathered offer over HTTPS. Bridges WebRTC's completion-handler API into
/// the `async` `CallMediaEngine` seam the `BridgeCallCoordinator` drives.
final class WebRTCCallMediaEngine: NSObject, CallMediaEngine, @unchecked Sendable {

    // One factory per process; RTCInitializeSSL is required once before use.
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
    }()

    private let audio: AudioSessionController
    private let lock = NSLock()
    private var peer: RTCPeerConnection?
    private var audioTrack: RTCAudioTrack?
    // Latched by close(). createOffer() suspends (offer creation, setLocalDescription)
    // and only publishes `peer` at the end, so a close() landing in that window would
    // otherwise find `peer == nil`, release nothing, and leave the connection it never
    // saw running with a live mic track. Every publish point re-checks this latch.
    private var closed = false
    private var stateHandler: (@Sendable (CallMediaState) -> Void)?
    // Non-trickle gather bookkeeping for the bridge path. Candidates are counted
    // per ICE generation (keyed by the local description's ice-ufrag) so a
    // renegotiation's wait isn't ended early by the previous generation's
    // candidates — with BUNDLE both share one transport, so the renegotiation
    // answer already carries them.
    private var candidateCounts: [String: Int] = [:]
    private var lastCandidateAt: [String: Date] = [:]
    private var endOfCandidates: Set<String> = []
    // Received agent track, muted/unmuted on barge-in.
    private var remoteAudioTrack: RTCAudioTrack?
    private var remoteAudioEnabled = true

    init(audio: AudioSessionController) {
        self.audio = audio
        super.init()
    }

    // MARK: - CallMediaEngine

    func createOffer(iceServers: [IceServer]) async throws -> String {
        // Manual-vs-automatic audio must be decided BEFORE the first audio track
        // exists (WebRTC starts the audio unit at track-ready time otherwise).
        // The flag is process-global, so a non-CallKit call must also RESET it —
        // a leftover `true` from a previous CallKit call would leave this call
        // waiting forever for a didActivate that never comes.
        //
        // Do NOT touch `isAudioEnabled` here: callKitConfigureAudioSession() gates
        // it off before the call and didActivate opens it — and because signaling
        // takes seconds, CallKit has usually ALREADY activated by the time this
        // runs. Re-gating here would stomp that activation and silence the call.
        // Already ended before setup even began — don't touch the process-global
        // audio session or build a peer nobody will ever close.
        try checkNotClosed()

        let rtcSession = RTCAudioSession.sharedInstance()
        rtcSession.useManualAudio = audio.callKitMode

        audio.activate() // configure (and, without CallKit, activate) the AVAudioSession

        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        // Bridge-provided STUN/TURN from the provision response (falls back to
        // Cloudflare STUN when it carries none); TURN entries carry credentials,
        // STUN entries don't.
        config.iceServers = (iceServers.isEmpty ? IceServer.defaultServers : iceServers).map { server in
            if let username = server.username, let credential = server.credential {
                return RTCIceServer(urlStrings: server.urls, username: username, credential: credential)
            }
            return RTCIceServer(urlStrings: server.urls)
        }

        let empty = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peer = Self.factory.peerConnection(with: config, constraints: empty, delegate: self) else {
            throw PolyError.voice(.mediaFailed("could not create the WebRTC peer connection"))
        }

        // Local microphone track (Opus).
        let source = Self.factory.audioSource(with: empty)
        let track = Self.factory.audioTrack(with: source, trackId: "audio0")
        peer.add(track, streamIds: ["stream0"])

        // Publish under the same lock that reads `closed`, so a close() either sees
        // this peer (and releases it) or has already latched (and we release it here).
        lock.lock()
        if closed {
            lock.unlock()
            peer.close()
            audio.deactivate()
            throw PolyError.voice(.mediaFailed("call ended during setup"))
        }
        self.peer = peer
        self.audioTrack = track
        lock.unlock()

        let offerConstraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio": "true"],
            optionalConstraints: nil
        )
        let offer = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<RTCSessionDescription, Error>) in
            peer.offer(for: offerConstraints) { sdp, error in
                if let sdp { cont.resume(returning: sdp) }
                else { cont.resume(throwing: error ?? PolyError.voice(.mediaFailed("offer creation failed"))) }
            }
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            peer.setLocalDescription(offer) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
        return offer.sdp
    }

    func acceptAnswer(sdp: String) async throws {
        guard let peer = currentPeer() else { throw PolyError.voice(.mediaFailed("no active peer connection")) }
        let answer = RTCSessionDescription(type: .answer, sdp: sdp)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            peer.setRemoteDescription(answer) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }

    func setStateHandler(_ handler: @escaping @Sendable (CallMediaState) -> Void) async {
        lock.lock(); stateHandler = handler; lock.unlock()
    }

    func setInterruptionHandler(_ handler: @escaping @Sendable (CallInterruption) -> Void) async {
        // The AVAudioSession interruption observer lives in the audio controller.
        audio.setInterruptionSink(handler)
    }

    func setAudioStateHandler(_ handler: @escaping @Sendable (AudioState) -> Void) async {
        audio.setAudioStateSink(handler)
    }

    func selectAudioDevice(_ device: AudioDevice?) async {
        audio.select(device)
    }

    func setMuted(_ muted: Bool) async {
        lock.lock(); let track = audioTrack; lock.unlock()
        track?.isEnabled = !muted
    }

    // MARK: - webrtc-bridge capabilities

    /// Wait for ICE gathering to settle before the offer is POSTed.
    ///
    /// Deliberately not `iceGatheringState == .complete`: a STUN transaction
    /// that never terminates pins that state at `.gathering` and suppresses the
    /// end-of-candidates event with it, so on some networks neither of WebRTC's
    /// two "done" signals ever arrives. A quiet candidate stream is the real
    /// signal; `cap` is only a backstop. The quiet timer arms only once a
    /// candidate exists, so a gather producing nothing falls through to the cap
    /// rather than returning an empty SDP immediately.
    func awaitIceGathering(quiet: TimeInterval, cap: TimeInterval) async {
        let deadline = Date().addingTimeInterval(cap)
        let step: UInt64 = 25_000_000 // 25ms
        while Date() < deadline {
            let key = currentIceUfrag() ?? ""
            lock.lock()
            let done = endOfCandidates.contains(key)
            let count = candidateCounts[key] ?? 0
            let last = lastCandidateAt[key]
            lock.unlock()
            if done { return }
            if currentPeer()?.iceGatheringState == .complete { return }
            if count > 0, let last, Date().timeIntervalSince(last) >= quiet { return }
            try? await Task.sleep(nanoseconds: step)
        }
    }

    func localDescriptionSDP() async -> String? {
        currentPeer()?.localDescription?.sdp
    }

    /// The mid of the transceiver carrying the microphone track.
    func audioMid() async -> String? {
        guard let peer = currentPeer() else { return nil }
        lock.lock(); let track = audioTrack; lock.unlock()
        guard let track else { return nil }
        return peer.transceivers.first { $0.sender.track?.trackId == track.trackId }?.mid
    }

    /// Apply the bridge's renegotiation offer (which adds the agent's recvonly
    /// m-line) and return the answer.
    func acceptRemoteOffer(sdp: String) async throws -> String {
        guard let peer = currentPeer() else {
            throw PolyError.voice(.mediaFailed("no active peer connection"))
        }
        let offer = RTCSessionDescription(type: .offer, sdp: sdp)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            peer.setRemoteDescription(offer) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
        let empty = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let answer = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<RTCSessionDescription, Error>) in
            peer.answer(for: empty) { sdp, error in
                if let sdp { cont.resume(returning: sdp) }
                else { cont.resume(throwing: error ?? PolyError.voice(.mediaFailed("answer creation failed"))) }
            }
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            peer.setLocalDescription(answer) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
        return answer.sdp
    }

    /// Barge-in: the SFU and jitter buffer already hold agent audio this client
    /// cannot drop, so the received track is muted the moment the bridge says so.
    func setRemoteAudioEnabled(_ enabled: Bool) async {
        lock.lock()
        remoteAudioEnabled = enabled
        let track = remoteAudioTrack
        lock.unlock()
        track?.isEnabled = enabled
    }

    private func currentIceUfrag() -> String? {
        guard let sdp = currentPeer()?.localDescription?.sdp else { return nil }
        for line in sdp.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("a=ice-ufrag:") {
                return String(trimmed.dropFirst("a=ice-ufrag:".count))
            }
        }
        return nil
    }

    func close() async {
        lock.lock()
        closed = true // latch first: a createOffer() still in flight will release its own peer
        let peer = self.peer
        self.peer = nil
        self.audioTrack = nil
        self.remoteAudioTrack = nil
        lock.unlock()
        peer?.close()
        if audio.callKitMode {
            // Defensive: if the call died without CallKit deactivating (e.g. a
            // signaling failure before the system ever activated), make sure the
            // audio unit can't start later on a dead call.
            RTCAudioSession.sharedInstance().isAudioEnabled = false
        }
        audio.deactivate()
    }

    // MARK: - Helpers

    private func currentPeer() -> RTCPeerConnection? {
        lock.lock(); defer { lock.unlock() }; return peer
    }

    private func checkNotClosed() throws {
        lock.lock(); let isClosed = closed; lock.unlock()
        if isClosed { throw PolyError.voice(.mediaFailed("call ended during setup")) }
    }

    private func emitState(_ state: CallMediaState) {
        lock.lock(); let handler = stateHandler; lock.unlock()
        handler?(state)
    }
}

// MARK: - RTCPeerConnectionDelegate

extension WebRTCCallMediaEngine: RTCPeerConnectionDelegate {

    /// Candidates are never trickled — the bridge's SDP proxy has no channel for
    /// them. They are only counted here, so `awaitIceGathering` can tell when the
    /// stream has gone quiet and the local description is complete enough to send.
    func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let key = candidate.sdp.ufragValue ?? currentIceUfrag() ?? ""
        lock.lock()
        if candidate.sdp.isEmpty {
            endOfCandidates.insert(key)
        } else {
            candidateCounts[key, default: 0] += 1
            lastCandidateAt[key] = Date()
        }
        lock.unlock()
    }

    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        switch newState {
        case .new: emitState(.new)
        case .connecting: emitState(.connecting)
        case .connected: emitState(.connected)
        case .disconnected: emitState(.disconnected)
        case .failed: emitState(.failed)
        case .closed: emitState(.closed)
        @unknown default: break
        }
    }

    /// The agent track arrives on the renegotiation, not the first answer.
    /// Capture it so barge-in can mute it, and honour a mute that fired before
    /// the (re-)pull delivered this track.
    func peerConnection(_ pc: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {
        guard let track = transceiver.receiver.track as? RTCAudioTrack else { return }
        lock.lock()
        remoteAudioTrack = track
        let enabled = remoteAudioEnabled
        lock.unlock()
        track.isEnabled = enabled
    }

    // Unused delegate requirements.
    func peerConnection(_ pc: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

/// Extract `ufrag` from a candidate's SDP attribute line, which is what keys the
/// gather bookkeeping to an ICE generation. A candidate from a retired
/// generation can still be delivered after a renegotiation installs the new
/// local description, so the local description alone is not a safe key.
private extension String {
    var ufragValue: String? {
        guard let range = self.range(of: "ufrag ") else { return nil }
        let rest = self[range.upperBound...]
        let value = rest.prefix { !$0.isWhitespace }
        return value.isEmpty ? nil : String(value)
    }
}
#endif
