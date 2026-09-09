# Voice 02-CallKit (SwiftUI)

[`01-Hello`](../01-Hello/)'s tap-to-call, promoted to a **system call** with CallKit: the green in-call indicator, lock-screen and AirPods/car-Bluetooth controls, rock-solid background audio, and — the big one — an incoming cellular call offers *hold* instead of silently killing the agent call.

## Run it

1. Open `VoiceCallKitSwiftUI.xcodeproj` (or `xcodegen generate` first if you changed `project.yml`).
2. Drop your **connector token** and **web calling token** into `PolyMessaging.initialize(...)` in `VoiceApp.swift` (both from Agent Studio › Connector Settings — see the [voice guide › Credentials](../../../../docs/PolyVoice.md#credentials)).
3. Everything the app needs is preconfigured in `project.yml`: the mic permission (`NSMicrophoneUsageDescription` — allow it on first call) and `UIBackgroundModes: [audio, voip]`. Note that **`voip` is required** — without it CallKit refuses every transaction (`requesttransaction Code=1`) and the Start button appears dead.
4. Run on a **physical device**. WebRTC media can't cross the simulator, and CallKit itself is broken there (iOS 17+ simulators auto-end the call; `didActivate` never fires) — on the simulator this example deliberately falls back to a plain `01-Hello`-style call.

## What this example demonstrates

- `VoiceOptions(callKit: true)` — the SDK defers all audio-session activation and audio-unit start/stop to CallKit.
- The three forwarding calls every CallKit app must make, from `CallKitController`:
  - `PolyVoice.callKitConfigureAudioSession()` in `perform(CXStartCallAction)` — configure early, **never** self-activate;
  - `PolyVoice.callKitAudioSessionDidActivate(_:)` in `provider(_:didActivate:)`;
  - `PolyVoice.callKitAudioSessionDidDeactivate(_:)` in `provider(_:didDeactivate:)`.
- The request/report split: user intents (start, end, mute) are **requested** via `CXCallController` and executed only in the provider's `perform` callbacks; remote events (agent hangup, failure) are **reported** via `reportCall(with:endedAt:reason:)`.
- Keeping the system UI in sync: mute from the app round-trips through `CXSetMutedCallAction`, so the lock-screen mute button and the in-app button never disagree.
- `includesCallsInRecents = false` — agent calls stay out of the Phone app's Recents.

## The CallKit flow

```
tap Start ─▶ CXCallController.request(CXStartCallAction)
                    │ system approves
                    ▼
        perform(CXStartCallAction)
            ├─ PolyVoice.callKitConfigureAudioSession()   // shape, no activation
            ├─ call.start()                               // signaling begins
            └─ action.fulfill() + reportOutgoingCall(startedConnectingAt:)
                    │ system activates the audio session
                    ▼
        provider(_:didActivate:) ─▶ PolyVoice.callKitAudioSessionDidActivate(_:)
                    │ media connects
                    ▼
        call.states → .connected ─▶ reportOutgoingCall(connectedAt:)   // timer starts
```

Hanging up mirrors it: the in-app button requests `CXEndCallAction`, `perform` calls `call.end()`, and `didDeactivate` forwards to the SDK. When the *agent* hangs up, the call state reaches `.ended` and the app **reports** `.remoteEnded` instead.

## Things to try on the device

- Start a call, **lock the screen** — the call keeps running; unlock to see the system call banner.
- Mute from the **system call UI** (long-press the green indicator) — the in-app button updates.
- Have someone **phone you** mid-agent-call — you get hold/decline instead of a dropped call.
- End the call from your **AirPods stem** or car controls.

## What this example skips

- **Inbound calls** — push-triggered ringing needs PushKit + backend support; PolyVoice is outbound-only today.
- **Hold/resume UX** — a held call (cellular interruption) resumes via CallKit's un-hold action; production apps should surface a "resume" affordance (see the voice guide's CallKit notes for the un-hold caveats).
- **China storefront gating** — Apple bans CallKit UI for apps distributed in China; gate `callKit:` off there (e.g. by region or remote config).

---

- **UIKit counterpart:** [`Examples/UIKit/Voice/02-CallKit/`](../../../UIKit/Voice/02-CallKit/)
- **Previous rung:** [`01-Hello`](../01-Hello/) — the same call without CallKit
- **SDK reference:** [voice guide › CallKit](../../../../docs/PolyVoice.md#callkit) · root [README](../../../../README.md)
