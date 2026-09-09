# Changelog

All notable changes to the PolyMessaging iOS SDK are documented here.
This project adheres to [Semantic Versioning](https://semver.org). While the SDK
is pre-1.0, breaking changes bump the **minor** version.

## [0.10.0] - 2026-09-09

### Changed
- **Voice calls now run over `webrtc-bridge`** instead of `webrtc-gateway` (MES-1658). The gateway
  path is gone, not deprecated — it no longer works.

  **No code change is required.** `PolyVoice.call(config:options:)`, `VoiceOptions`, `PolyCall`,
  `CallState`, mute, audio routing, CallKit and every error case are unchanged, and a call still
  links to the same messaging session. `start()` still returns with the call `.connecting`; watch
  `states` for `.connected` as before.

  What moved underneath: the call is provisioned with `POST /api/v1/call` (the web calling token
  becomes a Bearer credential), SDP travels over HTTPS non-trickle, the **bridge** mints the call id
  (so provision now runs before the messaging link), a second negotiation starts the agent's audio,
  a control socket carries barge-in and re-pull, and `DELETE /api/v1/call/{id}` replaces the close
  frame.
- `VoiceOptions.signalingHost` now overrides the **bridge** host rather than the gateway host. Same
  parameter, same meaning ("point voice at this deployment"), new target.
- `IceServer.defaultServers` is now Cloudflare STUN (`stun.cloudflare.com`). Media terminates at
  Cloudflare's edge on this path, so the old `stun.l.google.com` default went out with the gateway.

### Removed
- The gateway call pipeline: `CallCoordinator`, `SignalingProtocol`, `VoiceEnvironment` and the
  gateway ICE-servers fetch. All internal.
- Trickle-ICE members of the `@_spi(PolyVoice)` `CallMediaEngine` seam (`addRemoteCandidate`,
  `setLocalCandidateHandler`), replaced by `awaitIceGathering(quiet:cap:)`, `localDescriptionSDP()`,
  `audioMid()`, `acceptRemoteOffer(sdp:)` and `setRemoteAudioEnabled(_:)`. SPI, not public API.

### Deprecated
- `IceCandidate` — nothing in the public surface produces or consumes candidates now. Kept so
  existing code still compiles; scheduled for removal next minor.

## [0.9.0] - 2026-07-20

Adds **PolyVoice** — live, two-way WebRTC voice calls to a PolyAI agent — as a
**separate product/pod**, so chat-only apps never link the WebRTC binary. It supplies
a real `RTCPeerConnection` audio engine +
`AVAudioSession` control behind the existing, already-tested `CallCoordinator`
signaling pipeline.

### Added
- **`PolyVoice.call(config:options:)`** → a `PolyCall` backed by a real WebRTC audio
  engine (audio-only Opus, offer / answer / trickle ICE, mute). `VoiceOptions.webrtcToken`
  is required — a distinct token from the connector token.
- **CallKit support** (`PolyVoice`): opt in with `VoiceOptions(callKit: true)` to run a
  call as a system call. The SDK defers audio-session activation and the WebRTC audio
  unit to CallKit; three new statics forward the `CXProviderDelegate` moments —
  `PolyVoice.callKitConfigureAudioSession()`, `callKitAudioSessionDidActivate(_:)`,
  `callKitAudioSessionDidDeactivate(_:)`. New **Voice 02-CallKit** example (SwiftUI +
  UIKit) with the full provider wiring; [voice guide › CallKit](docs/PolyVoice.md#callkit).
- Public voice types on `PolyMessaging`: `CallState`, `AudioDevice`, `AudioState`,
  `IceServer`, `IceCandidate`, `CallMediaState` and `CallInterruption`.
  `CallMediaEngine` and `PolyCall.wired(...)` exist only so `PolyVoice` can inject its
  engine across the module boundary, so they are **SPI** (`@_spi(PolyVoice)`), not API —
  they stay refactorable and are not semver-locked.
- **`PolyCall` is an `ObservableObject`** (`@MainActor`), matching `ChatSession`: bind
  SwiftUI straight to the `@Published` `state` / `audioState`. The `states` /
  `audioStates` `AsyncStream`s remain for UIKit and other non-SwiftUI consumers.
- **Gateway ICE/TURN**: the call fetches STUN/TURN servers from the gateway per call, so it
  connects behind symmetric NAT / CGNAT (falls back to public STUN if the fetch fails).
- **Signaling auto-reconnect**: an unexpected signaling-socket drop reconnects with backoff
  (1s / 2s / 4s) on the same session and re-flushes buffered ICE, instead of failing on the
  first blip.
- **Audio-session interruptions**: an incoming phone call / Siri mutes the mic and restores
  it, or ends the call cleanly when the system won't let it resume.
- **`PolyError.Voice.disconnected` / `.interrupted`** (both `isRetryable`); a post-connect
  media drop now surfaces as the retryable `.disconnected` rather than `.mediaFailed`.
- **`VoiceOptions.signalingHost`** for a custom / self-hosted gateway. `PolyVoice.call(config:options:)`
  now `throws` — it validates inputs and reports `PolyError.invalidConfiguration` on a blank
  `apiKey`/`webrtcToken` or a `.custom` environment without a `signalingHost`.
- Mid-call audio **re-routing**: connecting/removing a headset or Bluetooth during a call now
  follows the route instead of staying stuck on the speaker.
- **Audio-output observation + control**: `PolyCall.audioState` (available outputs + the active one),
  `setAudioDevice(_:)` (speaker ↔ earpiece; accessories are system-routed), and `isMuted`.
- A SwiftUI + UIKit **Voice** example (tap-to-call, with mute + a speaker toggle).

### Fixed

Found by review before this ever shipped — listed because they're the failure modes
worth knowing about, not because any released version had them.

- **CallKit calls played out of the earpiece** instead of the loudspeaker: the audio
  route was never applied, because the route-change CallKit's activation fires was
  dropped by a guard that hadn't been armed yet.
- **Ending a call during setup leaked the peer connection and left the microphone
  live** — the recording indicator stayed lit for the rest of the app's lifetime.
- **Ending a call during a signaling reconnect leaked a WebSocket + URLSession** per
  occurrence: `open()` has no cancellation points, so cancelling the reconnect didn't
  stop it resuming a socket after teardown had finished.
- **A data race in the signaling channel**: `send()` was synchronized but `open()` /
  `close()` were not, and teardown races reconnect.
- **A healthy call could be failed by a routine ICE blip**: media states were delivered
  one unstructured `Task` per event, so `.disconnected` → `.connected` could apply in
  reverse and strand the call on the disconnect grace timer.
- ICE candidates gathered in the window just after a signaling reconnect were buffered
  with nothing left to flush them, and were lost for the rest of the call.
- Voice signaling hardening: offers/ICE are re-sent after a reconnect instead of being
  silently lost, stale socket callbacks can no longer corrupt a new connection, WS close
  codes are classified (clean close / terminal / retryable), `call.end()` now returns
  only after every resource (sockets, media engine, audio session) is released, and the
  audio session is never deactivated by a call that failed to acquire it.
- `PolyVoice.podspec` depends on `WebRTC-lib` (the pod that actually publishes M149).

## [0.8.0] - 2026-06-04

Add a `device_type` dimension (`mobile` / `tablet` / `desktop`) sent on session
create so analytics can segment traffic by form factor. It is detected
automatically from the device idiom (iPhone → mobile, iPad → tablet, Mac →
desktop) and is orthogonal to `platform` (`ios`), not a replacement. No action
required by integrators; no breaking changes.

## [0.7.0] - 2026-06-01

Add CocoaPods as a distribution channel. The SDK can now be installed with
`pod 'PolyMessaging', '~> 0.7'` alongside the existing Swift Package Manager
options. No API or behaviour changes.

## [0.6.0] - 2026-05-29

**Breaking change.** `Configuration.environment` now defaults to `.us` (US
production) instead of requiring an explicit value, and named production regions
were added — `.us`, `.uk`, `.euw` — alongside the existing `.cluster(_:)` and
`.custom(...)` cases. Apps relying on the previous behaviour should set
`environment:` explicitly to keep pointing at the same backend.

## [0.5.1] - 2026-05-28

Initial public release: fully managed chat over the PolyAI Messaging API — token
auth, session create/resume, WebSocket lifecycle, heartbeat, reconnection
with cursor-based replay, streaming chunk reassembly, optimistic send with
delivery tracking, and live-agent handoff, exposed through a SwiftUI/UIKit
bindable `ChatSession`. Dependency-free; iOS 15+ / macOS 12+.
