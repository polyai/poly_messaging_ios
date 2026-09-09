// Copyright PolyAI Limited

import Foundation

/// An ICE candidate exchanged with the WebRTC signaling gateway.
///
/// Public so the PolyVoice product's WebRTC engine can produce and consume them
/// across the module boundary — see ``CallMediaEngine``.
@available(*, deprecated, message: """
The SDK no longer trickles ICE: the bridge takes a fully-gathered offer over HTTPS, \
so nothing in the public surface produces or consumes candidates. Kept for source \
compatibility and scheduled for removal in the next minor release.
""")
public struct IceCandidate: Sendable, Equatable {
    public let candidate: String
    public let sdpMid: String?
    public let sdpMLineIndex: Int?

    public init(candidate: String, sdpMid: String?, sdpMLineIndex: Int?) {
        self.candidate = candidate
        self.sdpMid = sdpMid
        self.sdpMLineIndex = sdpMLineIndex
    }
}
