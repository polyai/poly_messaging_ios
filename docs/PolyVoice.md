# PolyVoice — WebRTC voice calling

Live, two-way WebRTC voice calls to a PolyAI agent — the companion to
[`PolyMessaging`](../README.md). It ships as a **separate product/pod** so chat-only
apps never link the WebRTC binary, and it reuses the messaging `Configuration` plus
the same `CallState` / `PolyError` vocabulary — no new concepts.

## Install

**Swift Package Manager** — add the package and depend on the `PolyVoice` product:

```swift
// Pre-1.0: breaking changes bump the MINOR version, so pin to next-minor.
.package(url: "https://github.com/polyai/ios-sdk.git", .upToNextMinor(from: "0.10.0"))
// target dependency (the package identity is the repo name, `ios-sdk`):
.product(name: "PolyVoice", package: "ios-sdk")
```

`PolyVoice` transitively pulls the WebRTC xcframework; `PolyMessaging` stays
source-only, so a chat-only target **links** only `PolyMessaging`.

> Note: with SPM, adding this repo resolves the WebRTC package for the whole
> dependency graph, so a chat-only target still *downloads* the xcframework even
> though it never links it. With CocoaPods the dependency lives solely in
> `PolyVoice.podspec`, so a chat-only `pod 'PolyMessaging'` install pulls nothing extra.

**CocoaPods**:

```ruby
pod 'PolyVoice', '~> 0.10.0'   # chat-only apps use `pod 'PolyMessaging'`
```

## Quick start

The smallest working call, in both toolkits. Make a new Xcode App project, drop your
connector token + web calling token into `PolyVoice.call(...)`, and Cmd+R on a physical
device (WebRTC media needs real hardware — see [Troubleshooting](#troubleshooting)).
Only `import PolyVoice` (plus `PolyMessaging` for the shared `Configuration` / `PolyError`
types) — no helper files to copy.

The core shape either way: `PolyVoice.call(config:options:)` returns a `PolyCall` —
observe its `state` (`.idle → .connecting → .connected → .ended` / `.failed`) and call
`start()` / `end()` / `setMuted(_:)`.

### SwiftUI

`PolyCall` is an `ObservableObject`, so a view that binds it re-renders itself on every
state / audio-route change — no `for await` loop to write.

```swift
// ContentView.swift
import SwiftUI
import PolyMessaging
import PolyVoice

struct ContentView: View {
    @State private var call: PolyCall?
    /// Only used before the first call exists (and to surface a construction failure) —
    /// once there's a `PolyCall`, `CallPanel` observes it directly.
    @State private var setupFailure: PolyError?

    var body: some View {
        VStack(spacing: 24) {
            Text("PolyAI Voice").font(.largeTitle.bold())

            if let call {
                CallPanel(call: call, onEnd: { self.call = nil })
            } else {
                Text(setupFailure.map { "Failed: \($0)" } ?? "Tap to call the agent")
                    .foregroundStyle(setupFailure == nil ? Color.secondary : Color.red)
                    .multilineTextAlignment(.center)
                Button(action: startCall) {
                    Text("Start call").frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
    }

    private func startCall() {
        // Fill in your connector from Agent Studio › Connector Settings.
        let config = Configuration(apiKey: "YOUR_CONNECTOR_TOKEN")
        do {
            let newCall = try PolyVoice.call(
                config: config,
                options: VoiceOptions(webrtcToken: "YOUR_WEB_CALLING_TOKEN")
            )
            setupFailure = nil
            call = newCall
            Task { try? await newCall.start() }
        } catch {
            setupFailure = error as? PolyError ?? .voice(.signalingFailed("\(error)"))
        }
    }
}

/// The live-call UI. Binding to `PolyCall` directly is the whole point: `state`
/// and `audioState` are `@Published`, so this view stays in sync on its own.
private struct CallPanel: View {
    @ObservedObject var call: PolyCall
    let onEnd: () -> Void

    @State private var muted = false

    var body: some View {
        VStack(spacing: 24) {
            Text(statusText)
                .foregroundStyle(statusColor)
                .multilineTextAlignment(.center)

            Button(action: toggleCall) {
                Text(buttonText).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(call.state.isActive ? .red : .accentColor)
            .disabled(isConnecting)

            if isConnected {
                Button(muted ? "Unmute" : "Mute") { toggleMute() }
                    .buttonStyle(.bordered)

                // iOS keeps one active output + auto-routes accessories; the app's real
                // control is speaker ↔ earpiece. Show the current route, toggle the speaker.
                if let selected = call.audioState.selectedDevice {
                    Text("Output: \(selected.name)").font(.caption).foregroundStyle(.secondary)
                    Button(isSpeaker ? "Speaker: on" : "Speaker: off") { toggleSpeaker() }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    // MARK: - Derived UI

    private var isConnecting: Bool { if case .connecting = call.state { return true }; return false }
    private var isConnected: Bool { if case .connected = call.state { return true }; return false }
    private var isSpeaker: Bool { call.audioState.selectedDevice?.kind == .speakerphone }

    private var statusText: String {
        switch call.state {
        case .idle: return "Tap to call the agent"
        case .connecting: return "Connecting…"
        case .connected: return "Connected — say hello 👋"
        case .ended: return "Call ended"
        case .failed(let error): return "Failed: \(error)"
        }
    }

    private var statusColor: Color {
        switch call.state {
        case .connected: return .green
        case .failed: return .red
        case .connecting: return .orange
        default: return .secondary
        }
    }

    private var buttonText: String {
        switch call.state {
        case .connecting: return "Connecting…"
        case .connected: return "End call"
        default: return "Start another call"
        }
    }

    // MARK: - Actions

    private func toggleCall() {
        if call.state.isActive {
            Task { await call.end() }
        } else {
            onEnd() // drop this call so the start screen can build a fresh one
        }
    }

    private func toggleMute() {
        muted.toggle()
        Task { await call.setMuted(muted) }
    }

    /// Flip between the loudspeaker and the earpiece. Accessories (headset/Bluetooth) are
    /// routed by the system automatically; this is the one output an app reliably controls.
    private func toggleSpeaker() {
        let target: AudioDevice.Kind = isSpeaker ? .earpiece : .speakerphone
        if let device = call.audioState.availableDevices.first(where: { $0.kind == target }) {
            Task { await call.setAudioDevice(device) }
        }
    }
}
```

> A fresh Xcode iOS App template's default `@main` `App` (`WindowGroup { ContentView() }`)
> needs no changes — `PolyVoice.call(...)` takes its `Configuration` directly, so there's
> no `PolyMessaging.initialize(...)` to add at launch (unlike the [chat quick start](../README.md#quick-start)).

### UIKit

```swift
//
//  CallViewController.swift
//

import UIKit
import PolyMessaging
import PolyVoice

/// The smallest voice call in UIKit: PolyVoice.call(...), observe state, start/end.
/// The UIKit counterpart of the SwiftUI Voice example.
final class CallViewController: UIViewController {

    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let callButton = UIButton(type: .system)
    private let muteButton = UIButton(type: .system)
    private let outputLabel = UILabel()
    private let speakerButton = UIButton(type: .system)

    private var call: PolyCall?
    private var observer: Task<Void, Never>?
    private var audioObserver: Task<Void, Never>?
    private var muted = false
    private var state: CallState = .idle { didSet { render() } }
    private var audioState: AudioState = .empty { didSet { renderAudio() } }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        titleLabel.text = "PolyAI Voice"
        titleLabel.font = .systemFont(ofSize: 34, weight: .bold)
        titleLabel.textAlignment = .center

        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.textColor = .secondaryLabel

        callButton.setTitle("Start call", for: .normal)
        callButton.titleLabel?.font = .systemFont(ofSize: 20, weight: .semibold)
        callButton.addTarget(self, action: #selector(toggleCall), for: .touchUpInside)

        muteButton.setTitle("Mute", for: .normal)
        muteButton.addTarget(self, action: #selector(toggleMute), for: .touchUpInside)
        muteButton.isHidden = true

        outputLabel.textAlignment = .center
        outputLabel.font = .systemFont(ofSize: 13)
        outputLabel.textColor = .secondaryLabel
        outputLabel.isHidden = true

        speakerButton.addTarget(self, action: #selector(toggleSpeaker), for: .touchUpInside)
        speakerButton.isHidden = true

        let stack = UIStackView(arrangedSubviews: [titleLabel, statusLabel, callButton, muteButton, outputLabel, speakerButton])
        stack.axis = .vertical
        stack.spacing = 20
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
        ])
        render()
    }

    @objc private func toggleCall() {
        if state.isActive {
            Task { await call?.end() }
        } else {
            startCall()
        }
    }

    private func startCall() {
        // Fill in your connector from Agent Studio › Connector Settings.
        let config = Configuration(apiKey: "YOUR_CONNECTOR_TOKEN")
        let newCall: PolyCall
        do {
            newCall = try PolyVoice.call(
                config: config,
                options: VoiceOptions(webrtcToken: "YOUR_WEB_CALLING_TOKEN")
            )
        } catch {
            state = .failed(error as? PolyError ?? .voice(.signalingFailed("\(error)")))
            return
        }
        muted = false
        call = newCall

        observer?.cancel()
        audioObserver?.cancel()
        let states = newCall.states
        observer = Task { [weak self] in
            for await newState in states {
                await MainActor.run { self?.state = newState }
            }
        }
        let audioStates = newCall.audioStates
        audioObserver = Task { [weak self] in
            for await snapshot in audioStates {
                await MainActor.run { self?.audioState = snapshot }
            }
        }
        Task { try? await newCall.start() }
    }

    @objc private func toggleMute() {
        muted.toggle()
        muteButton.setTitle(muted ? "Unmute" : "Mute", for: .normal)
        Task { await call?.setMuted(muted) }
    }

    // iOS keeps one active output + auto-routes accessories; speaker ↔ earpiece is the one
    // output an app reliably controls.
    @objc private func toggleSpeaker() {
        let isSpeaker = audioState.selectedDevice?.kind == .speakerphone
        let target: AudioDevice.Kind = isSpeaker ? .earpiece : .speakerphone
        if let device = audioState.availableDevices.first(where: { $0.kind == target }) {
            Task { await call?.setAudioDevice(device) }
        }
    }

    private func renderAudio() {
        let hasAudio = !audioState.availableDevices.isEmpty
        outputLabel.isHidden = !hasAudio
        speakerButton.isHidden = !hasAudio
        outputLabel.text = audioState.selectedDevice.map { "Output: \($0.name)" }
        let isSpeaker = audioState.selectedDevice?.kind == .speakerphone
        speakerButton.setTitle(isSpeaker ? "Speaker: on" : "Speaker: off", for: .normal)
    }

    private func render() {
        switch state {
        case .idle: statusLabel.text = "Tap to call the agent"
        case .connecting: statusLabel.text = "Connecting…"
        case .connected: statusLabel.text = "Connected — say hello 👋"
        case .ended: statusLabel.text = "Call ended"
        case .failed(let error): statusLabel.text = "Failed: \(error)"
        }
        switch state {
        case .connecting: callButton.setTitle("Connecting…", for: .normal)
        case .connected: callButton.setTitle("End call", for: .normal)
        default: callButton.setTitle("Start call", for: .normal)
        }
        callButton.isEnabled = { if case .connecting = state { return false }; return true }()
        muteButton.isHidden = { if case .connected = state { return false }; return true }()
    }
}
```

> A fresh Xcode iOS App template already wires an `AppDelegate` + `SceneDelegate` for you
> — no `PolyMessaging.initialize(...)` needed at launch (see the SwiftUI note above). Set
> `CallViewController` as the storyboard's initial view controller, or set
> `window.rootViewController = CallViewController()` in `SceneDelegate.scene(_:willConnectTo:options:)`.

`CallState`, `PolyError`, and `Configuration` are the same types from `PolyMessaging`.
Both examples above are runnable as-is from
[`Examples/SwiftUI/Voice/01-Hello`](../Examples/SwiftUI/Voice/01-Hello) ·
[`Examples/UIKit/Voice/01-Hello`](../Examples/UIKit/Voice/01-Hello) — see
[Microphone permission](#microphone-permission) and [Backgrounding](#backgrounding) below
before your first real call.

## Microphone permission

A call needs the microphone. Add **`NSMicrophoneUsageDescription`** to your app's
`Info.plist` (a call without it crashes on iOS). The system prompts on the first
call; the SDK activates the `AVAudioSession` for you (under [CallKit](#callkit),
the *system* activates it — the permission requirement is unchanged).

## Backgrounding

To keep a call running while your app is in the background (the norm for a voice call),
enable the **`audio` background mode** — add `UIBackgroundModes` to your `Info.plist`:

```xml
<key>UIBackgroundModes</key>
<array><string>audio</string></array>
```

The SDK holds a `playAndRecord` `AVAudioSession`, so with this mode the call keeps running
when the app is backgrounded; without it, iOS suspends the app and the call drops. All Voice
examples set this. By default a call is a normal app audio session, not a system phone call —
for the system call UI, see [CallKit](#callkit), which additionally requires the **`voip`**
background mode alongside `audio`.

## CallKit

Opt in with **`VoiceOptions(callKit: true)`** to run a call as a **system call**: the green
in-call indicator, lock-screen / AirPods / car-Bluetooth controls, phone-call audio priority,
and hold arbitration when a cellular call arrives. In this mode the SDK never activates or
deactivates the audio session itself — CallKit does — and your `CXProviderDelegate` must
forward three moments to the SDK:

```swift
func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
    PolyVoice.callKitConfigureAudioSession() // configure EARLY — never self-activate
    Task { try? await call.start() }
    action.fulfill()
    provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: nil)
}
func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    PolyVoice.callKitAudioSessionDidActivate(audioSession)   // audio starts HERE
}
func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    PolyVoice.callKitAudioSessionDidDeactivate(audioSession)
}
```

Rules the integration must follow (the **02-CallKit** examples encode all of them):

- **Declare the `voip` background mode** (alongside `audio`) in `UIBackgroundModes` —
  without it every `CXCallController` transaction is refused with
  `com.apple.CallKit.error.requesttransaction Code=1` (unentitled) and the call never starts.
- **Request, don't command:** start / end / mute go through `CXCallController` actions and
  are executed in the matching `perform` callback, so the system can arbitrate and the
  system UI stays in sync. Remote endings (the agent hangs up, a failure) are **reported**
  via `reportCall(with:endedAt:reason:)` instead.
- **Never call `AVAudioSession.setActive(true)`** during a CallKit call — a self-activated
  session blocks CallKit's elevated activation and `didActivate` never fires (the classic
  "call connects, no audio" bug).
- **System interruptions move to CallKit:** a cellular call arrives as a hold action +
  `didDeactivate`, not as the SDK's interruption handling (which stands down in this mode).
  After the interrupting call ends, iOS may not resume you automatically — offer a manual
  un-hold path.
- **Simulator:** CallKit is broken there (iOS 17+ auto-ends calls); gate on
  `targetEnvironment(simulator)` and fall back to a plain call, as the examples do.
- **China:** Apple rejects CallKit UI for the Chinese App Store; keep `callKit:` behind a
  region or remote-config gate if you ship there.

Inbound (push-triggered) calls are not supported — PolyVoice calls are app-initiated.

## Credentials

A voice call needs **two credentials**, both on your agent in
**[Agent Studio](https://studio.poly.ai) › Connector Settings** (the same connector
you use for chat):

| Value | What it is | Sent as |
|---|---|---|
| **Connector token** — `Configuration.apiKey` | your connector token | `X-Token` (authenticates the call) |
| **Web calling token** — `VoiceOptions.webrtcToken` | the media auth token — a **distinct** token from the connector token | `Authorization: Bearer` when the call is provisioned |

> **Region:** calls default to the US cluster. For a UK / EUW / other-region (or dev) agent, set the
> environment on the shared `Configuration` — e.g. `Configuration(apiKey: …, environment: .cluster("…"))`,
> the same `Configuration` you use for chat. See the [messaging guide](../README.md#configuration).
>
> **Custom / self-hosted host:** pass `VoiceOptions(webrtcToken:, signalingHost:)` to point at a
> specific `webrtc-bridge` deployment (required when the environment is `.custom`).

## How a call connects

Calls are placed over PolyAI's **`webrtc-bridge`**. The older `webrtc-gateway` path was removed in
MES-1658 — it is no longer operable, so there is nothing to choose between and **no API change**:
the same `PolyVoice.call(config:options:)` with the same two credentials.

What changed underneath, in case you're debugging a call:

| | before (gateway) | now (bridge) |
|---|---|---|
| Call setup | one signalling WebSocket | `POST /api/v1/call`, then SDP over HTTPS |
| Credential | token inside the SDP offer | `Authorization: Bearer` on provision |
| Call id | minted by this SDK | minted by the bridge (`call-<8 hex>`) |
| ICE | trickled after the offer | gathered **before** the offer is sent |
| Agent audio | arrived on the first answer | a second negotiation after connect |
| Media terminates at | PolyAI's gateway | Cloudflare's edge |
| STUN fallback | `stun.l.google.com` | `stun.cloudflare.com` |

Everything you bind to is unchanged: `PolyCall`, `CallState`, mute, audio routing, CallKit hooks and
errors, and the call still links to the same messaging session, so the agent transcript is the same.

`start()` still returns as soon as the call is under way, with the state `.connecting`; watch
`states` for `.connected` exactly as before. The agent-track negotiation that starts the agent's
audio runs after that, on your behalf.

> **Custom / self-hosted:** `VoiceOptions.signalingHost` now names the **bridge** host (required with
> a `.custom` environment).

## Audio routing

The call is **accessory-aware** by default: a connected wired/Bluetooth headset is used
automatically (and followed if connected or removed **mid-call**); otherwise it falls back to the
loudspeaker (hands-free — set `VoiceOptions(speakerphone: false)` for the earpiece instead).

iOS keeps **one** active output and routes accessories for you, so the output an app reliably
controls is **speaker ↔ earpiece**. Observe the live route via `call.audioState` and flip the
speaker with `call.setAudioDevice(_:)`:

```swift
Task { for await snapshot in call.audioStates {
    show(current: snapshot.selectedDevice)      // e.g. "Output: AirPods"
} }

// speaker ↔ earpiece — the entries come from snapshot.availableDevices
await call.setAudioDevice(speakerDevice)    // .kind == .speakerphone
await call.setAudioDevice(earpieceDevice)   // .kind == .earpiece
let muted = await call.isMuted
```

`audioState.availableDevices` also lists connected headsets/Bluetooth (`.kind` is
`.earpiece / .speakerphone / .wiredHeadset / .bluetooth`) for display. To let users pick *among*
connected outputs the iOS-standard way, drop in the system route picker (`AVRoutePickerView`).
Both example apps ship a **speaker toggle**.

## Troubleshooting

- **"Connector token was rejected" / fails while connecting** — both tokens come from the *same*
  connector in Agent Studio › Connector Settings, and the `Configuration` must match that
  connector's **environment** (region/cluster) and registered **host** (`hostIdentifier` /
  the app's bundle id). A token from one environment silently 401s on another.
- **Call connects but is silent (CallKit)** — the app isn't forwarding the provider
  callbacks: all three `PolyVoice.callKit*` calls are required (see [CallKit](#callkit)),
  and `UIBackgroundModes` must include `voip` or the call never starts at all
  (`requesttransaction Code=1`).
- **Call connects but is silent (no CallKit)** — check the mic permission was granted
  (Settings › *your app* › Microphone) and that nothing else in the app deactivated the
  `AVAudioSession` mid-call.
- **`failed(.voice(.timedOut))` after ~30 s** — signalling reached the bridge but media
  never connected: usually a firewalled/relay-only network where the TURN fetch failed
  (the SDK then falls back to STUN, which can't cross symmetric NAT). Check connectivity
  or the bridge's provision route.
- **Works on Wi-Fi, dies on the walk to the car** — transient drops reconnect
  automatically (see [Resilience](#resilience)); a `.disconnected` failure is retryable
  (`error.isRetryable`) — offer a redial button.
- **Nothing works on the simulator** — expected: WebRTC media needs a physical device,
  and CallKit is additionally broken on iOS 17+ simulators.

## Resilience

- **Connectivity:** STUN/TURN servers come from the bridge's provision response per call, so calls connect
  behind symmetric NAT / CGNAT (falls back to public STUN if the fetch fails).
- **Reconnect:** a dropped signaling socket reconnects automatically (backoff 1s / 2s / 4s) on
  the same session and re-flushes buffered ICE before the call is failed.
- **Interruptions:** an incoming phone call or Siri mutes the mic and restores it; a
  non-resumable interruption ends the call as `PolyError.voice(.interrupted)`.
- **Errors:** a post-connect drop surfaces as `PolyError.voice(.disconnected)`. Both it and
  `.interrupted` are `isRetryable`, so you can offer a one-tap retry.

## Architecture

`PolyVoice` provides a real `CallMediaEngine` (an `RTCPeerConnection` audio engine)
and an `AVAudioSession` controller, injected into a `PolyMessaging` call pipeline via
`PolyCall.wired(config:webrtcToken:signalingHost:transport:mediaEngine:)`
(SPI — `@_spi(PolyVoice)`, not public API).

There are two pipelines behind that seam, one per `VoiceTransport`, because the two backends
negotiate differently rather than merely talking over different sockets:

`BridgeCallCoordinator` runs the whole call:

| Step | What it does |
|---|---|
| 1-2 | access token, then a messaging session (`RestApi`) |
| 3 | `POST /api/v1/call` provisions the call and returns its id (`BridgeApi`) |
| 4 | links the messaging session to **that** id (`VoiceSessionLinker`) |
| 5 | the gathered offer over HTTPS, answer applied — `start()` returns here |
| 6-7 | media connects, then the agent track is pulled and renegotiated |
| 8 | the control socket carries barge-in and re-pull (`WebSocketEventsChannel`) |

Framing lives in `BridgeProtocol`. The whole pipeline is exercised over fakes in
`PolyMessagingTests` (no sockets, no WebRTC), and the media engine's non-trickle gather wait,
renegotiation answer, mid and remote-track muting are exercised against the real WebRTC engine in
`PolyVoiceTests` on an iOS simulator.
