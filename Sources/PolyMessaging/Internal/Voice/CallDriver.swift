// Copyright PolyAI Limited

import Foundation

/// The call pipeline behind ``PolyCall``.
///
/// Two implementations exist because the two backends negotiate differently,
/// not merely over different transports: ``CallCoordinator`` drives
/// `webrtc-gateway` (one WebSocket, trickle ICE, client-minted call SID) and
/// ``BridgeCallCoordinator`` drives `webrtc-bridge` (HTTPS SDP, a control
/// socket, a server-minted call id and a second negotiation for agent audio).
///
/// `PolyCall` holds one of these and knows about neither.
protocol CallDriver: Sendable {
    var stateStream: AsyncStream<CallState> { get }
    var audioStream: AsyncStream<AudioState> { get }

    func start() async throws
    func end() async
    func setMuted(_ muted: Bool) async
    var isMuted: Bool { get async }
    func selectAudioDevice(_ device: AudioDevice?) async
}

extension CallCoordinator: CallDriver {}
