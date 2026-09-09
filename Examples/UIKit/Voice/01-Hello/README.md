# Voice 01-Hello (UIKit)

The smallest possible voice call — build a `PolyCall`, observe its lifecycle, start / mute / end. One view controller, programmatic UI, no storyboard. The UIKit twin of [`SwiftUI/Voice/01-Hello`](../../../SwiftUI/Voice/01-Hello/).

## Run it

```bash
open VoiceUIKit.xcodeproj   # from this folder
```

1. Set your team under **Signing & Capabilities** (a device build needs one).
2. In `CallViewController.swift`, fill in both credentials from **Agent Studio › Connector Settings**: `apiKey` (your connector token, currently `"YOUR_CONNECTOR_TOKEN"`) and `webrtcToken` (the web calling token — a **distinct** value, currently `"YOUR_WEB_CALLING_TOKEN"`).
3. Run on a **physical iPhone** — the simulator can't carry WebRTC media. Allow the microphone, tap **Start call**, and talk.

Mic permission (`NSMicrophoneUsageDescription`) and the `audio` background mode are already configured via `project.yml`, so the call keeps running when you background the app.

## What this example demonstrates

- `PolyVoice.call(config:options:)` → a `PolyCall` (built, not yet started)
- `for await state in call.states` — `.idle → .connecting → .connected → .ended / .failed`
- `try await call.start()` after the mic permission, `await call.end()` any time
- `call.setMuted(_:)` for the local microphone
- `call.audioState` (published) + `call.setAudioDevice(_:)` — the speaker ↔ earpiece toggle

`PolyVoice` is a separate product so chat-only apps never link the WebRTC binary; it reuses `Configuration`, `CallState`, and `PolyError` from `PolyMessaging` — hence the two imports at the top of `CallViewController.swift`. The full reference is the [voice guide](../../../../docs/PolyVoice.md).

## How it works

Each subsection leads with **the SDK call** (the actual API), then shows **how it's wired into the view controller**.

### Build the call — `CallViewController.swift`

```swift
let call = try PolyVoice.call(
    config: Configuration(apiKey: "YOUR_CONNECTOR_TOKEN"),            // connector token
    options: VoiceOptions(webrtcToken: "YOUR_WEB_CALLING_TOKEN")   // web calling token — a distinct value
)   // throws PolyError.invalidConfiguration on a blank token,
    // or a .custom environment without VoiceOptions.signalingHost
```

`startCall()` wraps this in `do/catch` and keeps the result in a property:

```swift
do {
    newCall = try PolyVoice.call(config: config, options: VoiceOptions(webrtcToken: "…"))
} catch {
    state = .failed(error as? PolyError ?? .voice(.signalingFailed("\(error)")))
    return
}
call = newCall
```

**Under the hood:** building the call does no network work — it validates the tokens and wires the WebRTC engine to the same REST/session/signaling pipeline the SDK's tests exercise. Everything starts at `start()`. The two tokens do different jobs: the connector token authenticates the call session, the web calling token authenticates the signaling offer and the ICE-servers fetch.

*See [voice guide › Credentials](../../../../docs/PolyVoice.md#credentials).*

### Observe the lifecycle — `CallViewController.swift`

```swift
call.states       // AsyncStream<CallState> — late subscribers receive the current state first
call.state        // the current snapshot, if you just need one value
state.isActive    // true for .connecting and .connected
```

One `Task` folds the stream into a stored property whose `didSet` re-renders — the UIKit equivalent of SwiftUI's `@State`:

```swift
private var state: CallState = .idle { didSet { render() } }

observer = Task { [weak self] in
    for await newState in newCall.states {
        await MainActor.run { self?.state = newState }
    }
}
```

`render()` is one `switch` over `state` that sets the status label and the call button's title/enabled state — no separate bookkeeping. The `[weak self]` matters: the stream outlives a dismissed screen, and a strong capture would retain the controller for the life of the call. The previous observer is cancelled before each new call so a second call never receives the first call's states.

**Under the hood:** `states` replays the current state to late subscribers, so subscribing right after `PolyVoice.call(...)` can't miss a transition. A failed call lands on `.failed(PolyError)` — the same error vocabulary as chat.

*See [voice guide › Quick start](../../../../docs/PolyVoice.md#quick-start).*

### Start and end — `CallViewController.swift`

```swift
try await call.start()   // begins signaling + audio; iOS prompts for the mic on first use
await call.end()         // ends the call and releases resources — safe at any time
```

One button does both, keyed off `state.isActive`:

```swift
@objc private func toggleCall() {
    if state.isActive {
        Task { await call?.end() }
    } else {
        startCall()
    }
}
```

`render()` disables the button while `.connecting` so a double-tap can't race the handshake.

**Under the hood:** `start()` provisions the call on `webrtc-bridge`, sends a fully-gathered SDP offer over HTTPS, applies the answer, then renegotiates once media is up to pull the agent's audio — and activates a `playAndRecord` `AVAudioSession`. Mid-call drops and audio interruptions surface as `PolyError.Voice.disconnected` / `.interrupted` — both `isRetryable`, and the SDK reconnects transient drops itself before giving up.

*See [voice guide › Resilience](../../../../docs/PolyVoice.md#resilience).*

### Mute — `CallViewController.swift`

```swift
await call.setMuted(true)   // local microphone off; the agent's audio keeps playing
call.isMuted                // current value
```

The controller keeps a local `muted` flag for the button title and pushes it:

```swift
@objc private func toggleMute() {
    muted.toggle()
    muteButton.setTitle(muted ? "Unmute" : "Mute", for: .normal)
    Task { await call?.setMuted(muted) }
}
```

**Under the hood:** mute disables the local audio track — no renegotiation, instant in both directions.

### Speaker toggle — `CallViewController.swift`

```swift
call.audioStates                   // AsyncStream<AudioState> — availableDevices + selectedDevice;
                                   // .empty until the call's audio is engaged by start()
await call.setAudioDevice(device)  // route to an entry from availableDevices (nil = automatic)
```

A second observer `Task` folds `audioState` into a `didSet`-rendering property, exactly like the lifecycle stream. `renderAudio()` shows the live route and one toggle:

```swift
@objc private func toggleSpeaker() {
    let isSpeaker = audioState.selectedDevice?.kind == .speakerphone
    let target: AudioDevice.Kind = isSpeaker ? .earpiece : .speakerphone
    if let device = audioState.availableDevices.first(where: { $0.kind == target }) {
        Task { await call?.setAudioDevice(device) }
    }
}
```

iOS keeps one active output and routes accessories (headset, Bluetooth, CarPlay) itself — speaker ↔ earpiece is the one choice an app reliably owns, so that's the whole control surface. `VoiceOptions.speakerphone` (default `true`) picks the fallback route when no accessory is connected.

**Under the hood:** route changes are republished as `AudioState` snapshots, so `renderAudio()` updates from the stream — never flip the UI optimistically; wait for the snapshot that confirms the switch (plugging in a headset mid-call updates it too).

*See [voice guide › Audio routing](../../../../docs/PolyVoice.md#audio-routing).*

## What this example skips

- CallKit / system call UI — that is the next rung: [`02-CallKit`](../02-CallKit/), see also [voice guide › CallKit](../../../../docs/PolyVoice.md#callkit)
- reconnect and interruption UI — the SDK recovers transient drops itself, see [voice guide › Resilience](../../../../docs/PolyVoice.md#resilience)
- a custom / dev bridge — `VoiceOptions.signalingHost`, see [voice guide › Credentials](../../../../docs/PolyVoice.md#credentials)
- chat + voice in one app — the products compose; start from the chat ladder's [`01-Hello`](../../Chat/01-Hello/)

Further voice rungs will land alongside this one as `02-…`.

---

- **SwiftUI counterpart:** [`Examples/SwiftUI/Voice/01-Hello/`](../../../SwiftUI/Voice/01-Hello/)
- **SDK reference:** [voice guide](../../../../docs/PolyVoice.md) · root [README](../../../../README.md)
- **Install the package:** [voice guide → Install](../../../../docs/PolyVoice.md#install)
