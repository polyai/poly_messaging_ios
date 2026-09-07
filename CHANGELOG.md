# Changelog

All notable changes to the PolyMessaging iOS SDK are documented here.
This project adheres to [Semantic Versioning](https://semver.org). While the SDK
is pre-1.0, breaking changes bump the **minor** version.

## [Unreleased]

### Added
- **`VoiceTransport`** — choose the WebRTC backend a call uses:
  `VoiceOptions(webrtcToken:, transport: .bridge)` places the call over `webrtc-bridge`
  instead of `webrtc-gateway` (MES-1658). `.gateway` remains the default, so existing
  apps are unaffected.
- Bridge call pipeline (`BridgeCallCoordinator`): provision over
  `POST /api/v1/call`, SDP over HTTPS, a control socket for barge-in and agent-track
  re-pulls, and `DELETE /api/v1/call/{id}` teardown. The messaging session links to the
  **bridge-minted** call id, so provision now runs before the link on this path.
- Five `CallMediaEngine` capabilities behind the bridge path, all with default
  implementations so existing conformers keep compiling: `awaitIceGathering(quiet:cap:)`
  (non-trickle gathering), `localDescriptionSDP()`, `audioMid()`, `acceptRemoteOffer(sdp:)`
  (the agent-track renegotiation) and `setRemoteAudioEnabled(_:)` (barge-in).
- `IceServer.bridgeDefaultServers` — Cloudflare STUN, the fallback on the bridge path
  when the provision response carries no `iceServers` (RUN-1780).

### Changed
- `PolyCall` now holds any `CallDriver` rather than a concrete `CallCoordinator`, so the
  same public surface covers both backends. No public API change.

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
