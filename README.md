# PolyMessaging iOS SDK

[![CI](https://github.com/polyai/ios-sdk/actions/workflows/ci.yml/badge.svg)](https://github.com/polyai/ios-sdk/actions/workflows/ci.yml)
![Platform](https://img.shields.io/badge/platform-iOS%2015%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange)
![Dependencies](https://img.shields.io/badge/dependencies-none-green)
![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)
[![Develop with Claude Code](https://img.shields.io/badge/Develop%20with-Claude%20Code-DC9E63?logo=claude)](https://claude.ai/download)

Add AI-powered **chat** and **voice** to your iOS app. The SDK is **headless** — it handles token auth, the WebSocket, streaming, reconnection, delivery tracking, and live-agent handoff. You bring the UI.

- **[Quick start](#quick-start)** — paste a `ContentView` (SwiftUI) or `ViewController` (UIKit) into a fresh Xcode project and you have a working chat.
- **[Integration guide](#integration-guide)** — observe one object (`ChatSession`) and render the chat however you like.
- **[Voice calling](#voice-calling-polyvoice)** — live WebRTC voice calls with the separate `PolyVoice` product.

Reference: [Configuration](#configuration) · [Error handling](#error-handling) · [How it works](#how-it-works) · [Raw transport](#advanced-raw-transport) · [Example apps](#example-apps).

## Features

| | Feature | Description |
|---|---|---|
| 💬 | **Messaging** | Send and receive messages over WebSocket with typed Swift events |
| ⚡ | **Streaming** | Real-time chunks, auto-assembled — optionally rendered token-by-token |
| 🔄 | **Reconnection** | Automatic backoff + jitter, session resume, drops dead sockets the instant the OS reports offline |
| 🔐 | **Auth** | Token acquisition and session lifecycle — fully managed |
| 👤 | **Live agent** | Seamless handoff to humans with queue status and typing |
| 💡 | **Suggestions** | Quick-reply pills the agent offers, tap to send |
| 📎 | **Attachments** | Images, link cards, call-to-action phone buttons |
| 📡 | **Delivery tracking** | Optimistic send → confirmed → failed, per message |
| 🔧 | **Escape hatch** | Drop to the raw WebSocket transport for advanced use cases |
| 📞 | **Voice calling** | Live two-way WebRTC calls + audio-output routing ([`PolyVoice`](#voice-calling-polyvoice)) |

## Install

Add the package by its Git URL, pinned to a version. Pick **one** of the four options below.

### Option 1 — Xcode (recommended)

1. **File → Add Package Dependencies…**
2. Paste this URL into the **search field in the top-right** of the dialog:
   ```
   https://github.com/polyai/ios-sdk
   ```
3. Set **Dependency Rule** → *Up to Next Minor Version* → `0.11.0` (pre-1.0, breaking changes bump the **minor**)
4. Click **Add Package** → tick the **PolyMessaging** library for your app target → **Add Package** again.

### Option 2 — [CocoaPods](https://cocoapods.org) (`Podfile`)

```ruby
pod 'PolyMessaging', '~> 0.11.0'
```

Then run `pod install` and open the generated `.xcworkspace`.

### Option 3 — Swift Package Manager (`Package.swift`)

```swift
dependencies: [
    // Pre-1.0: breaking changes bump the MINOR version, so pin to next-minor.
    .package(url: "https://github.com/polyai/ios-sdk", .upToNextMinor(from: "0.11.0"))
]
// then add to your target:
.product(name: "PolyMessaging", package: "ios-sdk")
```

### Option 4 — [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`project.yml`)

```yaml
packages:
  PolyMessaging:
    url: https://github.com/polyai/ios-sdk
    exactVersion: 0.11.0      # or: upToNextMinorVersion: 0.11.0  (pre-1.0: minor bumps can break)
targets:
  YourApp:
    dependencies:
      - package: PolyMessaging
```

Then initialize once at app launch. The exact placement — SwiftUI's `@main` App init, or UIKit's `AppDelegate.application(_:didFinishLaunchingWithOptions:)` — is shown in full in the [Quick start](#quick-start) below.

> Your app's bundle identifier is sent automatically as the `X-Host` header — it must match the host registered in Agent Studio for your connector token.

---

# Quick start

The smallest thing that works. Make a new Xcode App project (File → New → Project → App), set your `apiKey`, paste, and Cmd+R. Only `import PolyMessaging` — no helper files to copy.

### SwiftUI

```swift
// MyApp.swift
import SwiftUI
import PolyMessaging

@main
struct MyApp: App {
    init() {
        PolyMessaging.initialize(.init(
            apiKey: "YOUR_CONNECTOR_TOKEN"   // Agent Studio → Connector Settings
        ))
    }
    var body: some Scene { WindowGroup { ContentView() } }
}
```

```swift
// ContentView.swift
import SwiftUI
import PolyMessaging

struct ContentView: View {
    @StateObject private var session = PolyMessaging.chat()
    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(session.messages) { message in
                        Text(message.text ?? "")
                            .padding(10)
                            .background(Color(.systemGray6))
                            .cornerRadius(12)
                    }
                }
                .padding()
            }
            HStack {
                TextField("Message", text: $text)
                    .textFieldStyle(.roundedBorder)
                Button("Send") {
                    let body = text; text = ""
                    Task { try? await session.send(body) }
                }
                .disabled(text.isEmpty)
            }
            .padding()
        }
    }
}
```

### UIKit

```swift
//
//  AppDelegate.swift
//

import UIKit
import PolyMessaging

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Initialize the SDK once at launch. No network happens here —
        // chat() / start() does the work later.
        PolyMessaging.initialize(.init(
            apiKey: "YOUR_CONNECTOR_TOKEN"   // Agent Studio → Connector Settings
        ))
        return true
    }

    // MARK: UISceneSession Lifecycle

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        // Called when a new scene session is being created.
        // Use this method to select a configuration to create the new scene with.
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        // Called when the user discards a scene session.
        // If any sessions were discarded while the application was not running, this will be called shortly after application:didFinishLaunchingWithOptions.
        // Use this method to release any resources that were specific to the discarded scenes, as they will not return.
    }
}
```

> A fresh Xcode iOS App template already wires a `SceneDelegate` and a storyboard for you. Either set `ViewController` as the storyboard's initial view controller, or set `window.rootViewController = ViewController()` in your `SceneDelegate.scene(_:willConnectTo:options:)`.

```swift
// ViewController.swift
import UIKit
import Combine
import PolyMessaging

final class ViewController: UIViewController, UITableViewDataSource {
    private let session = PolyMessaging.chat()
    private let tableView = UITableView()
    private let inputField = UITextField()
    private let sendButton = UIButton(type: .system)
    private var bag = Set<AnyCancellable>()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        tableView.dataSource = self
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)

        inputField.placeholder = "Message"
        inputField.borderStyle = .roundedRect
        inputField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(inputField)

        sendButton.setTitle("Send", for: .normal)
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sendButton)

        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: safe.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: inputField.topAnchor, constant: -8),
            inputField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            inputField.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -8),
            sendButton.leadingAnchor.constraint(equalTo: inputField.trailingAnchor, constant: 8),
            sendButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            sendButton.centerYAnchor.constraint(equalTo: inputField.centerYAnchor),
        ])

        // Re-render whenever the SDK updates the transcript.
        session.$messages
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.tableView.reloadData() }
            .store(in: &bag)
    }

    @objc private func sendTapped() {
        let body = inputField.text ?? ""
        guard !body.isEmpty else { return }
        inputField.text = ""
        Task { try? await session.send(body) }
    }

    // MARK: UITableViewDataSource
    func tableView(_ t: UITableView, numberOfRowsInSection s: Int) -> Int {
        session.messages.count
    }
    func tableView(_ t: UITableView, cellForRowAt i: IndexPath) -> UITableViewCell {
        let cell = t.dequeueReusableCell(withIdentifier: "cell", for: i)
        cell.textLabel?.text = session.messages[i.row].text ?? ""
        cell.textLabel?.numberOfLines = 0
        return cell
    }
}
```

**Streaming is on by default** — agent replies grow token-by-token (ChatGPT-style). To switch to complete-message bubbles instead, set `streamingEnabled: false` on the `Configuration` you pass to `initialize`:

```swift
PolyMessaging.initialize(.init(
    apiKey: "YOUR_CONNECTOR_TOKEN",
    streamingEnabled: false      // off → completed bubbles only
))
```

Full details in [Streaming](#streaming).

> **`chat()` vs `start()`** — `chat()` resumes the previous conversation if one exists (within ~10 minutes — the server's WebSocket idle timeout), else starts fresh; `start()` always starts fresh. `PolyMessaging.hasResumableSession()` tells you which to offer.
> **Lifecycle:** initialize once; keep one `ChatSession` per chat surface (`@StateObject` / a stored property); call `await session.client.shutdown()` when the surface goes away for good.

---

# Integration guide

The SDK is headless: it gives you one observable object — **`ChatSession`** — and your UI is *whatever you build by observing its state.*

## Voice calling (`PolyVoice`)

Live, two-way **WebRTC voice calls** to a PolyAI agent ship in a **separate** product/pod —
[`PolyVoice`](docs/PolyVoice.md) — so chat-only apps never link the WebRTC binary (`PolyMessaging`
stays source-only; note that SPM still *resolves* the xcframework for the graph, while a
CocoaPods chat-only install pulls nothing extra). It reuses the messaging `Configuration` and the same `CallState` / `PolyError` types.

```swift
import PolyMessaging
import PolyVoice

PolyMessaging.initialize(.init(
    apiKey: "YOUR_CONNECTOR_TOKEN",       // connector token
    webrtcToken: "YOUR_WEB_CALLING_TOKEN" // web calling token — distinct; both from Agent Studio
))

// Elsewhere — no config to pass, PolyVoice.call() reads what initialize(...) set:
let call = try PolyVoice.call()
Task { for await state in call.states { render(state) } }   // .connecting → .connected → …
try await call.start()   // after the microphone permission (NSMicrophoneUsageDescription) is granted
```

Calls are placed over PolyAI's **`webrtc-bridge`** (the older `webrtc-gateway` was retired in
MES-1658). Nothing changes in your code — see [How a call connects](docs/PolyVoice.md#how-a-call-connects)
for what moved underneath.

A call needs **two credentials, both required and distinct**, from
[Agent Studio](https://studio.poly.ai) › **Connector Settings** (the same connector you use for chat):
the **connector token** (`Configuration.apiKey`, authenticates the connector) and the **web calling token**
(`Configuration.webrtcToken` — or `VoiceOptions.webrtcToken`, which wins if both are set —
authenticates the media backend). Setting `webrtcToken` once on `Configuration` means the same
value you pass to `PolyMessaging.initialize(...)` for chat also covers every `PolyVoice.call()`.
Pass a `Configuration` explicitly — `PolyVoice.call(config:options:)` — for a call that needs a
different connector than the one `initialize(...)` set.

Add **`PolyVoice`** via SPM (`.product(name: "PolyVoice", package: "ios-sdk")`) or CocoaPods
(`pod 'PolyVoice'`). **📖 Full guide → [`docs/PolyVoice.md`](docs/PolyVoice.md)** — credentials, the
microphone permission, accessory-aware audio routing, [CallKit](docs/PolyVoice.md#callkit)
(system call UI via `VoiceOptions(callKit: true)`), and the architecture.
Runnable demos: [`Examples/SwiftUI/Voice`](Examples/SwiftUI/Voice/01-Hello/) ·
[`Examples/UIKit/Voice`](Examples/UIKit/Voice/01-Hello/).

## Meet `ChatSession`

`PolyMessaging.chat()` (or `start()`) returns a `@MainActor` `ChatSession` — an `ObservableObject`. It assembles streaming, tracks delivery, manages typing, dedups resumes, and surfaces handoff — so your UI only ever reads state and calls methods. SwiftUI binds it with `@StateObject`; UIKit sinks its `@Published` properties with Combine.

**State you observe** (all `@Published`, read-only):

| Property | Type | What it tells you |
|---|---|---|
| `messages` | `[ChatMessage]` | every message in the conversation, in order — `ChatMessage` is an enum whose cases are `.user(UserMessage)` (what you sent), `.agent(AgentMessage)` (what the bot or live human sent back), and `.system(SystemMessage)` (events like "agent joined" or "conversation ended"). Iterate it to render the chat. |
| `isReady` | `Bool` | connected and ready to send |
| `connection` | `ConnectionStatus` | socket state — `.connecting` / `.open` / `.reconnecting(n)` / `.failed` / … |
| `isAgentTyping` | `Bool` | show the typing indicator |
| `agentAvatarUrl` | `URL?` | latest agent / live-agent avatar |
| `hasStarted` | `Bool` | the conversation has begun |
| `hasEnded` | `Bool` | conversation is over — swap the composer for a "start new" CTA |
| `failureReason` | `PolyError?` | non-nil once the chat hits a terminal failure it can't auto-recover from — invalid connector token, reconnect budget exhausted, session expired |

**Methods you call:**

| Member | What it does |
|---|---|
| `send(_:) async throws` | send a user message (optimistic — appears immediately as `.pending`) |
| `sendTyping() async` | tell the agent you're typing (safe every keystroke; throttled) |
| `end() async throws` | end the conversation |
| `removeMessage(draftId:)` | drop a failed draft (call before re-sending on retry) |
| `clearSuggestions(for:)` | clear one message's quick-reply pills |
| `clearChat()` | wipe the transcript (e.g. before `startNewSession()`) |
| `userMessages` / `agentMessages` / `systemMessages` / `lastAgentMessage` | filtered views of `messages` |
| `client` | the underlying `PolyMessagingClient` — `events`, `startNewSession()`, `resume()`, `shutdown()`, `getConnection()` |

## Starting, resuming & ending a session

`chat()` and `start()` both return a `ChatSession`; the difference is whether they reuse the last conversation:

- **`chat()`** — resume the stored session if it's still valid (within the session timeout, ~10 minutes — matches the backend's WebSocket idle timeout), else start fresh. **This is the default** — conversations survive an app relaunch.
- **`start()`** — always discard any stored session and begin a new one. Use it for an explicit "New chat" entry point.

Before showing the chat, you can offer the choice:

```swift
if PolyMessaging.hasResumableSession() {
    // offer "Resume previous chat?" → PolyMessaging.chat()
} else {
    // PolyMessaging.start()
}
```

Then observe `hasStarted` / `hasEnded` and use these methods on the live session:

| Call | When |
|---|---|
| `try await session.send(text)` | send a message |
| `try await session.end()` | end the conversation (flips `hasEnded`) |
| `session.clearChat()` | wipe the on-screen transcript immediately |
| `try await session.client.startNewSession()` | end the current chat and begin a fresh one **in place** (same `ChatSession`/client) |
| `try await session.client.resume()` | reconnect after a terminal `.failed` (see [Connection & reconnect](#connection--reconnect)) |

A user-initiated `end()` flips `hasEnded` with no "conversation ended" pill; an agent- or server-initiated end shows the pill (it arrives as a `.system` message). For a "Start New Chat" button, call `clearChat()` then `startNewSession()`.

> **Lifecycle & cleanup:** call `PolyMessaging.initialize(...)` once at launch; keep **one** `ChatSession` per chat surface (`@StateObject` in SwiftUI, a stored property in UIKit) — each new session is a fresh REST handshake; and call `await session.client.shutdown()` when the surface is dismissed for good (idempotent — cancels heartbeat, reconnect, and retry tasks). `ChatSession` is `@MainActor`: observe and mutate it from the main actor.

## The core pattern: render `messages` yourself

`messages` is `[ChatMessage]`, where `ChatMessage` is an enum — `.user(UserMessage)`, `.agent(AgentMessage)`, `.system(SystemMessage)`, each `Identifiable`. **Every chat UI is the same shape: iterate `messages` and `switch` over the case.** This one pattern renders *everything* — text, agent vs user, system pills, handoff, live agents.

```swift
// SwiftUI — drop this inside your ContentView's `var body: some View`.
// Re-renders automatically whenever the SDK updates `messages` (new message,
// delivery update, streaming text growth).
ScrollView {
    LazyVStack(alignment: .leading, spacing: 8) {
        ForEach(session.messages) { message in
            switch message {
            case .user(let m):
                Text(m.text)                                  // your sent bubble
                    .padding(10).background(.blue).foregroundColor(.white)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            case .agent(let m):
                Text(m.text)                                  // agent bubble; tint live humans
                    .padding(10)
                    .background(m.agentKind == .live ? Color.teal.opacity(0.18) : Color(.systemGray5))
            case .system(let m):
                Text(systemLabel(m.event))                    // centered status pill
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }
    .padding()
}
```

```swift
// UIKit — re-render whenever the SDK updates the transcript.
override func viewDidLoad() {
    super.viewDidLoad()
    // ...your existing setup (register cell, set dataSource, layout)...

    session.$messages
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in self?.tableView.reloadData() }
        .store(in: &bag)
}

// UIKit — UITableViewDataSource methods.
func tableView(_ t: UITableView, numberOfRowsInSection s: Int) -> Int {
    session.messages.count
}

func tableView(_ t: UITableView, cellForRowAt i: IndexPath) -> UITableViewCell {
    let cell = t.dequeueReusableCell(withIdentifier: "cell", for: i)
    switch session.messages[i.row] {
    case .user(let m):   cell.textLabel?.text = m.text
    case .agent(let m):  cell.textLabel?.text = m.text
    case .system(let m): cell.textLabel?.text = systemLabel(m.event)
    }
    return cell
}
```

> **`text` optionality:** the unwrapped values above — `UserMessage.text` / `AgentMessage.text` — are non-optional `String`. The top-level convenience `ChatMessage.text` (handy if you don't `switch`) is `String?`, so use `?? ""` when reading it directly.

**What each case carries** (the fields you render):

- **`UserMessage`** — `text`, `delivery` (`.pending` / `.sent` / `.failed`), `draftId`.
- **`AgentMessage`** — `text` (Markdown), `agentKind` (`.poly` / `.live`), `agentName`, `avatarUrl`, `attachments`, `suggestions`, `callActions`.
- **`SystemMessage`** — `event: SystemEvent` (handoff steps, queue status, conversation-ended, …).

`SystemEvent` is what your `systemLabel(_:)` switches on:

```swift
// A free helper — paste alongside your ContentView / ViewController.
// Used by both snippets above to label `.system` cases.
func systemLabel(_ event: SystemEvent) -> String {
    switch event {
    case .handoffStarted:                    return "Transferring you to an agent…"
    case .handoffRequired(let reason):       return "Agent connection issue: \(reason)"
    case .queueStatus(let pos, let msg):     return msg ?? pos.map { "You're #\($0) in line" } ?? "Waiting…"
    case .handoffAccepted:                   return "An agent will be with you shortly"
    case .liveAgentJoined(let name):         return "\(name ?? "An agent") joined"
    case .liveAgentLeft, .agentLeft, .conversationEnded: return "Conversation ended"
    case .handoffFailed(let reason):         return "Transfer failed: \(reason ?? "unknown")"
    case .handoffTimeout:                    return "No agents available right now"
    case .idleWarning:                       return "Connection idle — you may be disconnected soon"
    case .serverMessage(let text, _):        return text
    // No default — `SystemEvent` is fully covered above; future cases
    // will surface as a compiler error so you remember to add them.
    }
}
```

That's the foundation. The rest of this section is just *which field or case* each feature uses.

## Adding each feature

> **UIKit snippets below** assume `import Combine` at the top of the file (the per-section snippets omit it for brevity — only the Quick Start shows it). SwiftUI doesn't need it.

### Streaming
The agent's reply arrives as a sequence of chunks. `ChatSession` reassembles them for you and updates `messages` — you never touch chunks directly. You only choose **how a reply appears**, with **one** switch.

**`Configuration.streamingEnabled`** (default `true`) is the single knob — set it once at `initialize(...)` and you're done:

- **`streamingEnabled: true`** (default) → the bubble appears immediately and **grows token-by-token** as chunks land (ChatGPT-style), then settles into the final, fully-formatted message.
- **`streamingEnabled: false`** → the server sends complete messages only; the bubble appears whole when ready. While the agent thinks, `isAgentTyping` is `true` — show the typing dots.

```swift
PolyMessaging.initialize(.init(
    apiKey: "YOUR_CONNECTOR_TOKEN",
    streamingEnabled: true       // default — set to false for complete messages only
))

// Then anywhere in your app — no extra args needed.
let session = PolyMessaging.chat()
```

**Need to override for one surface?** `chat()` / `start()` accept an optional `streamingEnabled:` argument. Pass it only if you want this session to differ from the config default; otherwise leave it off.

```swift
let alt = PolyMessaging.chat(streamingEnabled: false)   // this surface only
```

Either way, your render code — the `switch` over `messages` from [the core pattern](#the-core-pattern-render-messages-yourself) — doesn't change.

*Example app:* [01-Hello (SwiftUI)](Examples/SwiftUI/Chat/01-Hello/) · [01-Hello (UIKit)](Examples/UIKit/Chat/01-Hello/) — both stream agent replies by default (just `PolyMessaging.chat()` with the default config). For a live toggle to compare with `streamingEnabled: false` side by side, see [07-Playground](Examples/SwiftUI/Chat/07-Playground/).

### Connection & reconnect
**Data:** `session.connection` — show a banner only while `.reconnecting` (drops go `.open → .reconnecting(n) → .open`, no `.closed` flash). `session.failureReason` is terminal — offer `client.resume()`. Use `isConnected` / `isReconnecting` / `isFailed` (full list under [Connection states](#connection-states)).

```swift
// SwiftUI
var body: some View {
    VStack(spacing: 0) {
        if case .reconnecting = session.connection {
            Text("Reconnecting…").font(.caption)
                .frame(maxWidth: .infinity).padding(6).background(.yellow.opacity(0.15))
        }
        if session.failureReason != nil {
            Button("Try again") { Task { try? await session.client.resume() } }
        }

        // ...your existing UI (message list, composer, etc.)...
    }
}
```
```swift
// UIKit
private let reconnectBanner = UILabel()             // your own banner UIView
private var bag = Set<AnyCancellable>()             // for Combine subscriptions

override func viewDidLoad() {
    super.viewDidLoad()
    // ...your existing setup (add reconnectBanner to view, etc.)...

    session.$connection
        .receive(on: RunLoop.main)
        .sink { [weak self] status in
            self?.reconnectBanner.isHidden = !status.isReconnecting
            if status.isFailed { self?.showRetry { Task { try? await self?.session.client.resume() } } }
        }
        .store(in: &bag)
}

// Your own helper that surfaces a retry CTA — e.g. show an alert with a
// "Try again" action that calls the closure.
private func showRetry(_ retry: @escaping () -> Void) { /* … */ }
```
*Example app:* [02-Standard (SwiftUI)](Examples/SwiftUI/Chat/02-Standard/) · [02-Standard (UIKit)](Examples/UIKit/Chat/02-Standard/)

**Device offline is a separate signal.** `session.connection` tracks the *socket*, not whether the *phone* lost Wi-Fi. For that, watch the OS network path with `Network.NWPathMonitor` and show a distinct "You're offline" bar — the two can stack: offline (device) on top, reconnecting (socket) below. See [04-Resilience](Examples/SwiftUI/Chat/04-Resilience/).

### Terminal errors
**Data:** `session.failureReason` (non-nil whenever the chat hits a terminal failure it can't auto-recover from — an invalid `apiKey` rejected at the initial connect, the reconnect budget exhausted, or the session expiring. The one state that needs the user). `PolyError` isn't `LocalizedError`, so use `String(describing: reason)`, not `.localizedDescription`.

```swift
// SwiftUI
var body: some View {
    ZStack {
        // ...your existing chat UI...

        if let reason = session.failureReason {
            VStack(spacing: 12) {
                Text("Connection lost").font(.headline)
                Text(String(describing: reason)).foregroundStyle(.secondary)
                Button("Try again") { Task { try? await session.client.resume() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
        }
    }
}
```
```swift
// UIKit
private let errorView = UIView()                    // your own full-screen overlay
private let errorLabel = UILabel()                  // inside errorView
private let retryButton = UIButton(type: .system)   // inside errorView; wire below
private var bag = Set<AnyCancellable>()

override func viewDidLoad() {
    super.viewDidLoad()
    // ...your existing setup (add errorView etc. on top of the chat)...

    retryButton.addAction(UIAction { _ in
        Task { try? await self.session.client.resume() }
    }, for: .touchUpInside)

    session.$failureReason
        .receive(on: RunLoop.main)
        .sink { [weak self] reason in
            self?.errorView.isHidden = (reason == nil)
            self?.errorLabel.text = reason.map { String(describing: $0) }
        }
        .store(in: &bag)
}
```
*Example app:* [04-Resilience (SwiftUI)](Examples/SwiftUI/Chat/04-Resilience/) · [04-Resilience (UIKit)](Examples/UIKit/Chat/04-Resilience/) (full-screen `TerminalErrorScreen`) · [06-FullReference (SwiftUI)](Examples/SwiftUI/Chat/06-FullReference/) · [06-FullReference (UIKit)](Examples/UIKit/Chat/06-FullReference/) (in a screen state machine)

### Loading & empty states
**Data:** `isReady` (false until connected) + `messages.isEmpty`. Show a skeleton until the first messages arrive, then swap to the transcript.

```swift
// SwiftUI
var body: some View {
    if !session.isReady && session.messages.isEmpty {
        ProgressView("Connecting…")
    } else {
        // ...your existing chat UI (message list, composer, etc.)...
    }
}
```
```swift
// UIKit
private let spinner = UIActivityIndicatorView(style: .large)
private let tableView = UITableView()               // from Quick start
private var bag = Set<AnyCancellable>()

override func viewDidLoad() {
    super.viewDidLoad()
    // ...your existing setup (add spinner + tableView to view, etc.)...

    // Re-check the loading state whenever either signal changes.
    Publishers.CombineLatest(session.$isReady, session.$messages)
        .receive(on: RunLoop.main)
        .sink { [weak self] ready, messages in
            let showSpinner = !ready && messages.isEmpty
            self?.spinner.isHidden = !showSpinner
            showSpinner ? self?.spinner.startAnimating() : self?.spinner.stopAnimating()
            self?.tableView.isHidden = showSpinner
        }
        .store(in: &bag)
}
```
*Example app:* [04-Resilience (SwiftUI)](Examples/SwiftUI/Chat/04-Resilience/) · [04-Resilience (UIKit)](Examples/UIKit/Chat/04-Resilience/)

### Delivery state & retry
**Data:** `UserMessage.delivery` is a `Delivery` enum (`.pending` → `.sent` → `.failed`). Restyle the bubble per state; on `.failed`, drop the draft with `removeMessage(draftId:)` then re-send so you don't duplicate. Tip: delay the "Sending…" label ~500 ms so fast confirmations don't flash it.

```swift
// SwiftUI
ForEach(session.messages) { message in
    switch message {
    case .user(let m):
        VStack(alignment: .trailing, spacing: 2) {
            Text(m.text).padding(10)
                .background(m.delivery == .failed ? Color.red.opacity(0.15) : .blue)
            if m.delivery == .failed {
                Button("Tap to retry") {
                    session.removeMessage(draftId: m.draftId)
                    Task { try? await session.send(m.text) }
                }
            } else if m.delivery == .pending {
                Text("Sending…").font(.caption2).foregroundStyle(.secondary)
            }
        }

    // ...other cases (.agent, .system) — see the core pattern...
    default: EmptyView()
    }
}
```
```swift
// UIKit — `cell` is your MessageCell (with messageLabel + statusLabel).
// Cell class shown in the collapsible below.
func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath) as! MessageCell
    let message = session.messages[indexPath.row]
    cell.messageLabel.text = message.text ?? ""
    cell.statusLabel.isHidden = true

    if case .user(let m) = message {
        switch m.delivery {
        case .pending: cell.statusLabel.text = "Sending…"; cell.statusLabel.isHidden = false
        case .sent:    cell.statusLabel.isHidden = true
        case .failed:  cell.statusLabel.text = "Tap to retry"; cell.statusLabel.isHidden = false
        }
    }
    return cell
}

func retry(_ m: UserMessage) {
    session.removeMessage(draftId: m.draftId)
    Task { try? await session.send(m.text) }
}
```

<details>
<summary>Show <code>MessageCell</code> (subviews + constraints)</summary>

```swift
// Register with `tableView.register(MessageCell.self, forCellReuseIdentifier: "cell")`.
final class MessageCell: UITableViewCell {
    let messageLabel = UILabel()
    let statusLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        messageLabel.numberOfLines = 0
        let stack = UIStackView(arrangedSubviews: [messageLabel, statusLabel])
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}
```

</details>

*Example app:* [02-Standard (SwiftUI)](Examples/SwiftUI/Chat/02-Standard/) · [02-Standard (UIKit)](Examples/UIKit/Chat/02-Standard/)

### Typing
**Data:** `isAgentTyping` (+ `agentAvatarUrl`) shows the dots; call `sendTyping()` on every keystroke to tell the agent — throttled, auto-STOPPED after 5 s idle, and `isAgentTyping` clears on the next agent message.

```swift
// SwiftUI
var body: some View {
    VStack(spacing: 0) {
        // ...your existing message list...

        if session.isAgentTyping {
            Text("typing…").font(.caption).foregroundStyle(.secondary)
        }

        TextField("Message", text: $text)
            .onChange(of: text) { _ in Task { await session.sendTyping() } }
    }
}
```
```swift
// UIKit
private let typingLabel = UILabel()                 // your "typing…" label
private let inputField = UITextField()              // your composer (from Quick start)
private var bag = Set<AnyCancellable>()

override func viewDidLoad() {
    super.viewDidLoad()
    // ...your existing setup (add typingLabel + inputField to view)...

    session.$isAgentTyping
        .receive(on: RunLoop.main)
        .sink { [weak self] typing in self?.typingLabel.isHidden = !typing }
        .store(in: &bag)

    inputField.addAction(UIAction { [weak self] _ in
        Task { await self?.session.sendTyping() }
    }, for: .editingChanged)
}
```
*Example app:* [02-Standard (SwiftUI)](Examples/SwiftUI/Chat/02-Standard/) · [02-Standard (UIKit)](Examples/UIKit/Chat/02-Standard/)

### Suggestions (quick replies)
**Data:** `AgentMessage.suggestions` (`[ResponseSuggestion]`, agent-only). Render under the last message; on tap, clear then send. Only the latest agent message shows pills, and they scroll away with history.

```swift
// SwiftUI
ForEach(session.messages) { message in
    // ...your bubble rendering for this message...

    if case .agent(let agent) = message,
       message.id == session.messages.last?.id,
       !agent.suggestions.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(agent.suggestions) { suggestion in
                    Button(suggestion.messageText) {
                        session.clearSuggestions(for: message.id)
                        Task { try? await session.send(suggestion.messageText) }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }
}
```
```swift
// UIKit — `cell` is your MessageCell (with messageLabel + suggestionsStack).
// Cell class shown in the collapsible below.
func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath) as! MessageCell
    let message = session.messages[indexPath.row]
    cell.messageLabel.text = message.text ?? ""
    cell.suggestionsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

    if case .agent(let agent) = message,
       message.id == session.messages.last?.id,
       !agent.suggestions.isEmpty {
        for suggestion in agent.suggestions {
            let button = UIButton(type: .system)
            button.setTitle(suggestion.messageText, for: .normal)
            button.addAction(UIAction { [weak self] _ in
                self?.session.clearSuggestions(for: message.id)
                Task { try? await self?.session.send(suggestion.messageText) }
            }, for: .touchUpInside)
            cell.suggestionsStack.addArrangedSubview(button)
        }
    }
    return cell
}
```

<details>
<summary>Show <code>MessageCell</code> (subviews + constraints)</summary>

```swift
final class MessageCell: UITableViewCell {
    let messageLabel = UILabel()
    let suggestionsStack = UIStackView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        messageLabel.numberOfLines = 0
        suggestionsStack.axis = .horizontal
        suggestionsStack.spacing = 8

        let outer = UIStackView(arrangedSubviews: [messageLabel, suggestionsStack])
        outer.axis = .vertical
        outer.spacing = 8
        outer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(outer)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            outer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            outer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            outer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}
```

</details>

*Example app:* [02-Standard (SwiftUI)](Examples/SwiftUI/Chat/02-Standard/) · [02-Standard (UIKit)](Examples/UIKit/Chat/02-Standard/)

### Rich text & links
**Data:** `AgentMessage.text` is the agent's text, delivered **raw**. It's usually Markdown — `**bold**`, `*italic*`, `` `code` ``, `[links](https://…)` — but it can also contain a small subset of **HTML** (most commonly `<br>` line breaks), because the backend serves the same message to the web chat widget, which renders it as HTML. The SDK never strips or converts it — you render it (see the HTML note below).

```swift
// SwiftUI
ForEach(session.messages) { message in
    switch message {
    case .agent(let m):
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: m.text, options: opts) {
            Text(attributed)
        } else {
            Text(m.text)
        }

    // ...other cases (.user, .system) — see the core pattern...
    default: EmptyView()
    }
}
```
```swift
// UIKit — `cell.textView` is a UITextView on your MessageCell (NOT a
// UILabel — labels render Markdown links visually but don't make them
// tappable). Cell class shown in the collapsible below.
func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath) as! MessageCell
    if case .agent(let m) = session.messages[indexPath.row] {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        cell.textView.attributedText = (try? AttributedString(markdown: m.text, options: opts)).map(NSAttributedString.init)
    }
    return cell
}
```

<details>
<summary>Show <code>MessageCell</code> (subviews + constraints)</summary>

```swift
final class MessageCell: UITableViewCell {
    let textView = UITextView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        textView.isEditable = false
        textView.isScrollEnabled = false              // self-sizes in the cell
        textView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            textView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            textView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            textView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}
```

</details>

> `AttributedString(markdown:)` doesn't linkify *bare* URLs — add a regex pass if your agent sends them, and be tolerant of half-open Markdown during progressive streaming.

> **Handling HTML (`<br>` & friends).** Because the same agent text is rendered by the web chat widget as HTML, a reply can arrive with literal tags — e.g. `…how can I help?<br><br>Pick an option:`. `AttributedString(markdown:)` does **not** convert HTML, so those tags would render raw. The advanced examples ([`03-RichContent`](Examples/SwiftUI/Chat/03-RichContent/), [`06-FullReference`](Examples/SwiftUI/Chat/06-FullReference/), and the rest of `03`–`07`, in **both** SwiftUI and UIKit) run a small `normalizeAgentHTML` pass first that mirrors the web widget's DOMPurify allow-list — `a, br, b, i, em, strong, p, ul, ol, li, code` — mapping `<br>`→newline, `<b>`/`<strong>`→`**`, `<i>`/`<em>`→`*`, `<a href>`→`[text](url)`, lists→bullets, decoding HTML entities, and dropping any other tag. The minimal [`01-Hello`](Examples/SwiftUI/Chat/01-Hello/) / [`02-Standard`](Examples/SwiftUI/Chat/02-Standard/) examples deliberately skip it (they render `m.text` plainly to stay minimal), so they show `<br>` raw — copy `normalizeAgentHTML` from `RichText.swift` / `MessageCell.swift` if your agent emits HTML.

*Example app:* [03-RichContent (SwiftUI)](Examples/SwiftUI/Chat/03-RichContent/) · [03-RichContent (UIKit)](Examples/UIKit/Chat/03-RichContent/)

### Attachments, link cards & call buttons
An agent message can carry images, link preview-cards, and `tel:` call buttons — all on `AgentMessage`. Filter `attachments` by `contentType` and render each kind; drop `.unknown` (it exists for forward-compat).

**Data:** `AgentMessage.attachments` (`[Attachment]`) and `AgentMessage.callActions` (`[ChatCallAction]`).
- `Attachment`: `contentType` (`.image` / `.url` / `.unknown`), `contentUrl`, `previewImageUrl`, `title`, `callToActionText`
- `ChatCallAction`: `title`, `contactNumber`

```swift
// SwiftUI
struct ChatView: View {
    @StateObject private var session = PolyMessaging.chat()
    // SwiftUI-qualified because the SDK also exports an `Environment` type.
    @SwiftUI.Environment(\.openURL) private var openURL

    var body: some View {
        ForEach(session.messages) { message in
            switch message {
            case .agent(let m):
                // Images
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(m.attachments.filter { $0.contentType == .image }, id: \.contentUrl) { att in
                            AsyncImage(url: att.contentUrl) { $0.resizable().scaledToFill() } placeholder: { Color(.systemGray5) }
                                .frame(width: 160, height: 120).clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                // URL cards — horizontal carousel, like the images above
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(m.attachments.filter { $0.contentType == .url }, id: \.contentUrl) { att in
                            if let url = att.contentUrl {
                                Link(att.title ?? url.absoluteString, destination: url)
                            }
                        }
                    }
                }
                // Tel: buttons
                ForEach(m.callActions) { action in
                    Button("\(action.title) · \(action.contactNumber)") {
                        let digits = action.contactNumber.filter { $0.isNumber || $0 == "+" }
                        if let url = URL(string: "tel:\(digits)") { openURL(url) }
                    }
                    .buttonStyle(.borderedProminent)
                }

            // ...other cases (.user, .system) — see the core pattern...
            default: EmptyView()
            }
        }
    }
}
```
```swift
// UIKit — `cell` is your MessageCell (with imageStack + callsStack).
// Cell class shown in the collapsible below.
func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath) as! MessageCell
    cell.imageStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    cell.callsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    guard case .agent(let m) = session.messages[indexPath.row] else { return cell }

    for att in m.attachments where att.contentType == .image {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        if let url = att.contentUrl {
            URLSession.shared.dataTask(with: url) { data, _, _ in
                guard let data, let image = UIImage(data: data) else { return }
                DispatchQueue.main.async { iv.image = image }
            }.resume()
        }
        cell.imageStack.addArrangedSubview(iv)
    }

    for action in m.callActions {
        let button = UIButton(type: .system)
        button.setTitle("\(action.title) · \(action.contactNumber)", for: .normal)
        button.addAction(UIAction { _ in
            let digits = action.contactNumber.filter { $0.isNumber || $0 == "+" }
            if let url = URL(string: "tel:\(digits)") { UIApplication.shared.open(url) }
        }, for: .touchUpInside)
        cell.callsStack.addArrangedSubview(button)
    }

    return cell
}
```

<details>
<summary>Show <code>MessageCell</code> (subviews + constraints)</summary>

```swift
final class MessageCell: UITableViewCell {
    let imageStack = UIStackView()
    let callsStack = UIStackView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        imageStack.axis = .horizontal; imageStack.spacing = 8
        callsStack.axis = .vertical;   callsStack.spacing = 6

        let outer = UIStackView(arrangedSubviews: [imageStack, callsStack])
        outer.axis = .vertical; outer.spacing = 8
        outer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(outer)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            outer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            outer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            outer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}
```

</details>

Each link card opens `contentUrl` on tap; call buttons dial a sanitized `tel:` (digits + leading `+`).

*Example app:* [03-RichContent (SwiftUI)](Examples/SwiftUI/Chat/03-RichContent/) · [03-RichContent (UIKit)](Examples/UIKit/Chat/03-RichContent/)

### Live agent handoff
**No special listening** — handoff is already in `messages`: progress as `.system` events (your `systemLabel(_:)` from the core pattern renders them), live-agent replies as `.agent` with `agentKind == .live`, live typing via `isAgentTyping`. Just tint the live agent so the user can tell a human took over.

```swift
// SwiftUI
ForEach(session.messages) { message in
    switch message {
    case .agent(let m):
        let isLive = m.agentKind == .live
        if isLive, let name = m.agentName {
            Text("\(name) · live agent").font(.caption).foregroundStyle(.teal)
        }
        Text(m.text).padding(10)
            .background(isLive ? Color.teal.opacity(0.18) : Color(.systemGray5))

    // ...other cases (.user, .system) — see the core pattern...
    default: EmptyView()
    }
}
```
```swift
// UIKit — `cell` is your MessageCell (with bubble + nameLabel + messageLabel).
// Cell class shown in the collapsible below.
func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath) as! MessageCell
    if case .agent(let m) = session.messages[indexPath.row] {
        let isLive = (m.agentKind == .live)
        cell.bubble.backgroundColor = isLive ? UIColor.systemTeal.withAlphaComponent(0.18) : .systemGray5
        cell.nameLabel.text = isLive ? "\(m.agentName ?? "Agent") · live agent" : m.agentName
        cell.messageLabel.text = m.text
    }
    return cell
}
```

<details>
<summary>Show <code>MessageCell</code> (subviews + constraints)</summary>

```swift
final class MessageCell: UITableViewCell {
    let bubble = UIView()
    let nameLabel = UILabel()
    let messageLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        messageLabel.numberOfLines = 0
        bubble.layer.cornerRadius = 8

        let labels = UIStackView(arrangedSubviews: [nameLabel, messageLabel])
        labels.axis = .vertical
        labels.spacing = 2
        labels.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(labels)
        bubble.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(bubble)
        NSLayoutConstraint.activate([
            bubble.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            bubble.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            bubble.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -12),
            bubble.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            labels.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 8),
            labels.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 10),
            labels.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -10),
            labels.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -8),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}
```

</details>

`.liveAgentLeft` is terminal (the SDK flips `hasEnded`). To deep-link a handoff route, observe [`client.events`](#side-effects-clientevents).

*Example app:* [05-Handoff (SwiftUI)](Examples/SwiftUI/Chat/05-Handoff/) · [05-Handoff (UIKit)](Examples/UIKit/Chat/05-Handoff/)

### Message timestamps
**Data:** `ChatMessage.timestamp` (also on each `UserMessage` / `AgentMessage` / `SystemMessage`).

```swift
// SwiftUI
ForEach(session.messages) { message in
    VStack(alignment: .leading, spacing: 2) {
        Text(message.text ?? "")                    // ...your bubble rendering...

        Text(message.timestamp, style: .time)       // e.g. "3:42 PM"
            .font(.caption2).foregroundStyle(.secondary)
    }
}
```
```swift
// UIKit — `cell` is your MessageCell (with messageLabel + timeLabel).
// Cell class shown in the collapsible below.
func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath) as! MessageCell
    let message = session.messages[indexPath.row]
    cell.messageLabel.text = message.text ?? ""
    let f = DateFormatter(); f.timeStyle = .short
    cell.timeLabel.text = f.string(from: message.timestamp)
    return cell
}
```

<details>
<summary>Show <code>MessageCell</code> (subviews + constraints)</summary>

```swift
final class MessageCell: UITableViewCell {
    let messageLabel = UILabel()
    let timeLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        messageLabel.numberOfLines = 0
        timeLabel.font = .preferredFont(forTextStyle: .caption2)
        timeLabel.textColor = .secondaryLabel

        let stack = UIStackView(arrangedSubviews: [messageLabel, timeLabel])
        stack.axis = .vertical
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}
```

</details>

For a date-grouped separator row (when the gap between consecutive messages crosses a date boundary, insert a row with the date), see the playground.

*Example app:* [07-Playground (SwiftUI)](Examples/SwiftUI/Chat/07-Playground/) · [07-Playground (UIKit)](Examples/UIKit/Chat/07-Playground/)

### Avatars & keyboard
**Data:** `agentAvatarUrl` (latest) and `AgentMessage.avatarUrl` (per-message). Keyboard handling is yours.

```swift
// SwiftUI
// NOTE: scrollDismissesKeyboard is iOS 16+, but the SDK supports iOS 15 — guard it
// (e.g. wrap in a ViewModifier behind `if #available(iOS 16, *)`) or it won't compile
// on an iOS-15 deployment target.
var body: some View {
    ScrollView {
        ForEach(session.messages) { message in
            switch message {
            case .agent(let m):
                HStack(alignment: .top, spacing: 8) {
                    AsyncImage(url: m.avatarUrl) { $0.resizable().scaledToFill() }
                        placeholder: { Color(.systemGray5) }
                        .frame(width: 28, height: 28).clipShape(Circle())

                    Text(m.text)                    // ...your bubble rendering...
                }

            // ...other cases (.user, .system) — see the core pattern...
            default: EmptyView()
            }
        }
    }
    .scrollDismissesKeyboard(.interactively)        // iOS 16+
}
```
```swift
// UIKit — `cell` is your MessageCell (with avatarView + messageLabel).
// Cell class shown in the collapsible below.
func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath) as! MessageCell
    if case .agent(let m) = session.messages[indexPath.row] {
        cell.messageLabel.text = m.text
        if let url = m.avatarUrl {
            URLSession.shared.dataTask(with: url) { data, _, _ in
                guard let data, let image = UIImage(data: data) else { return }
                DispatchQueue.main.async { cell.avatarView.image = image }
            }.resume()
        }
    }
    return cell
}

// Keyboard pin lives on the view controller — pin your input bar to
// keyboardLayoutGuide.topAnchor (instead of the safe-area bottom) so it
// rides the keyboard with no notification observers.
inputBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor).isActive = true
```

<details>
<summary>Show <code>MessageCell</code> (subviews + constraints)</summary>

```swift
final class MessageCell: UITableViewCell {
    let avatarView = UIImageView()
    let messageLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        avatarView.clipsToBounds = true
        avatarView.layer.cornerRadius = 14
        avatarView.contentMode = .scaleAspectFill
        messageLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [avatarView, messageLabel])
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .top
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            avatarView.widthAnchor.constraint(equalToConstant: 28),
            avatarView.heightAnchor.constraint(equalToConstant: 28),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}
```

</details>

*Example app:* [05-Handoff (SwiftUI)](Examples/SwiftUI/Chat/05-Handoff/) · [05-Handoff (UIKit)](Examples/UIKit/Chat/05-Handoff/)

## Side effects: `client.events`

Rendering reads `messages`. For **imperative reactions** — navigate, play a haptic, log analytics — observe the typed event stream instead. (This is the lower-level API `ChatSession` is built on; reach for it only for side effects.)

```swift
// SwiftUI — attach .task to your chat view; the Task is cancelled when the
// view goes away.
var body: some View {
    VStack {
        // ...your existing UI (message list, composer, etc.)...
    }
    .task {
        for await event in session.client.events {
            switch event {
            case .liveAgentJoined(_, let agent):
                haptics.success(); analytics.track("handoff", agent.agentName)
            case .clientHandoffRequired(_, let payload):
                if let route = payload.route, let url = URL(string: route) { await UIApplication.shared.open(url) }
            case .sessionEnd(_, _):
                analytics.track("chat_ended")
            default:
                break
            }
        }
    }
}
```
```swift
// UIKit — store the Task as a property and cancel it in deinit.
private var eventsTask: Task<Void, Never>?

override func viewDidLoad() {
    super.viewDidLoad()
    // ...your existing setup...

    eventsTask = Task { [weak self] in
        guard let self else { return }
        for await event in session.client.events {
            switch event {
            case .liveAgentJoined(_, let agent):
                haptics.success(); analytics.track("handoff", agent.agentName)
            case .clientHandoffRequired(_, let payload):
                if let route = payload.route, let url = URL(string: route) { await UIApplication.shared.open(url) }
            case .sessionEnd(_, _):
                analytics.track("chat_ended")
            default:
                break
            }
        }
    }
}

deinit { eventsTask?.cancel() }
```

> Tie the `Task` to your view's lifecycle (SwiftUI `.task { }`, or cancel in `deinit`). Subscribe **before** sending — `events` is lazy-start.

### In-app new-message alerts (local-only workaround)

A common ask: pop a notification banner when the agent replies. ⚠️ **This is a local-notification *workaround*, not remote push** — and there is **no remote push (APNs) functionality in the SDK yet (coming soon).** The SDK's realtime connection only delivers **while your app is running**, so you drive the banner off the **completed-message events** on `client.events` and schedule an immediate **local** notification. Delivery therefore degrades with app state:

| App state | Banner? |
|---|---|
| **Foreground** | ✅ fires immediately |
| **Background — brief grace window (~30s)** | ⚠️ yes, *if* you hold a `beginBackgroundTask` (the example `NewMessageNotifier` does) |
| **Suspended / locked / force-quit** | ❌ never — iOS has torn the socket down |

**Choosing *when* it fires — `NotificationPolicy`.** A banner shouldn't interrupt you while you're *reading* the conversation, so the example `NewMessageNotifier` takes a policy (default: quiet while the chat is on screen):

| Policy | Behaviour |
|---|---|
| `.whenBackgrounded` *(default)* | No banner while the chat is on screen — only when it isn't (the background grace window). |
| `.always` | Banner on every new agent message, even with the chat open in the foreground. |
| `.never` | Off. |

Flip it at the call site: SwiftUI `.newMessageNotifications(for: session, policy: .whenBackgrounded)`; UIKit `messageNotifier.start(observing: session, policy: .whenBackgrounded)`. (The table above is about *deliverability* — whether a banner can show at all; the policy is *your choice* of when to, within that.)

**Real lock-screen delivery when the app is closed needs APNs + a server-side push integration** — device-token registration plus a backend that pushes on each new message. That isn't built yet (**coming soon**), and there's no client-only substitute: `BGAppRefreshTask` can poll-and-notify when iOS *opportunistically* wakes the app, but it's best-effort and iOS-timed, not instant.

**How it works — the gist.** Become the notification-center delegate (so iOS shows the banner even while you're *in* the app), watch `client.events` for *completed* agent messages, skip any you've already shown, and post an immediate **local** notification while the app is foreground or inside the grace window.

> **Foreground + a short grace window — and that's the client-side ceiling.** The example `NewMessageNotifier` holds a `beginBackgroundTask` on backgrounding so a reply landing in the ~30s before iOS suspends the app still banners. We never use a time-based trigger (it could fire long after suspension). Beyond that window — suspended, locked, or killed — nothing arrives client-side; lock-screen delivery is an **APNs + backend push** feature (not built yet — **coming soon**), see the table above.

**Step by step** — each step shows the idea, then the code. Steps 1–5 are plain `UserNotifications` + the SDK's `client.events`, so the code is **identical in SwiftUI and UIKit**; the only per-framework difference is the wiring (where the loop runs, how the grace task is held), shown for **both** in *Putting it together* below.

**1. Become the foreground delegate.** Set a `UNUserNotificationCenterDelegate` whose `willPresent` returns `[.banner, .sound]` — otherwise iOS suppresses banners for the *active* app — and request authorization once, up front.

```swift
final class ForegroundBannerPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
        withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])                      // show the banner even while foreground
    }
}

let center = UNUserNotificationCenter.current()
center.delegate = bannerPresenter                    // your ForegroundBannerPresenter
center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
```

**2. Listen for *completed* messages.** Consume `session.client.events` and act only on `.agentMessage` / `.liveAgentMessage` — each carries the **whole** reply `text` and a stable, server-assigned `messageId`. Ignore the partial `.agentMessageChunk`s, so the banner shows the full reply, not the first streamed token.

```swift
// `client.events` is multicast, so observing it doesn't disturb the ChatSession driving your UI.
for await event in session.client.events {
    let msg: (id: String, title: String, body: String)?
    switch event {
    case .agentMessage(_, let p):     msg = (p.messageId, p.agentName ?? "New message", p.text)
    case .liveAgentMessage(_, let p): msg = (p.messageId, p.agentName ?? "New message", p.text)
    default:                          msg = nil       // ignore .agentMessageChunk etc.
    }
    guard let msg else { continue }
    // …steps 3–5 run here, once per completed message…
}
```

**3. Dedupe — persisted.** Keep a **bounded** `UserDefaults`-backed set of shown `messageId`s. The SDK replays the conversation on resume / reconnect / relaunch, so an *in-memory* guard isn't enough; persist it and replays are silently skipped.

```swift
struct NotifiedMessageStore {
    private let key = "poly.notifiedMessageIds"
    private var seen: Set<String>
    init() { seen = Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
    func contains(_ id: String) -> Bool { seen.contains(id) }
    mutating func markShown(_ id: String) {
        guard seen.insert(id).inserted else { return }
        // (cap the stored list in real code so it can't grow unbounded)
        UserDefaults.standard.set(Array(seen), forKey: key)
    }
}

guard !store.contains(msg.id) else { continue }      // skip a message we've already shown
```

**4. Gate on app state *and* policy.** A banner can only show when the app is `.active` **or** the background grace window is open — a `beginBackgroundTask` you hold from `didEnterBackground` until foreground (or until iOS expires it). On top of that, the policy decides *whether* to: the default `.whenBackgrounded` stays quiet while the chat is on screen (foreground), so a reply you're already watching arrive doesn't also banner. Either way, mark it shown so a later resume-replay can't re-notify.

```swift
let active = UIApplication.shared.applicationState == .active   // foreground == viewing this chat
let wantBanner = policy == .always || !active                   // .whenBackgrounded: quiet on screen
let canDeliver = active || graceWindowIsOpen                    // graceWindowIsOpen: a held beginBackgroundTask
if wantBanner && canDeliver { /* step 5: post */ }
store.markShown(msg.id)                                         // mark every message, posted or not
```

**5. Post immediately.** Build the content and add a request with `trigger: nil` (deliver now) — **never** a time-based trigger, which could fire long after suspension — then mark it shown.

```swift
let content = UNMutableNotificationContent()
content.title = msg.title; content.body = msg.body; content.sound = .default
UNUserNotificationCenter.current().add(
    UNNotificationRequest(identifier: msg.id, content: content, trigger: nil))
store.markShown(msg.id)
```

**6. Streaming-safe — no extra code.** With streaming on, the agent message's `id` is stable across chunks, so step 3's dedupe yields exactly **one** banner per reply (with the opening tokens).

**Putting it together** — the loop and grace window wire up a little differently per framework:

```swift
// SwiftUI — run the loop in `.task` (auto-cancelled with the view); hold the
// background grace task while backgrounded via scenePhase.
.onAppear {
    let center = UNUserNotificationCenter.current()
    center.delegate = bannerPresenter                       // your ForegroundBannerPresenter
    center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
}
.task {
    for await event in session.client.events { /* steps 2–5: match → dedupe → gate → post */ }
}
.onChange(of: scenePhase) { phase in                        // graceWindowIsOpen = a held beginBackgroundTask
    switch phase {
    case .background: graceTask.begin()
    case .active:     graceTask.end()
    default:          break
    }
}
```
```swift
// UIKit — run the loop in a Task you cancel in deinit; hold the grace task via
// the background / foreground notifications.
override func viewDidLoad() {
    super.viewDidLoad()
    let center = UNUserNotificationCenter.current()
    center.delegate = self                                  // the VC is the UNUserNotificationCenterDelegate
    center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

    let nc = NotificationCenter.default
    nc.addObserver(self, selector: #selector(didBackground),
                   name: UIApplication.didEnterBackgroundNotification, object: nil)
    nc.addObserver(self, selector: #selector(willForeground),
                   name: UIApplication.willEnterForegroundNotification, object: nil)

    notifyTask = Task { [weak self] in
        guard let self else { return }
        for await event in self.session.client.events { /* steps 2–5: match → dedupe → gate → post */ }
    }
}
@objc private func didBackground()  { graceTask.begin() }   // beginBackgroundTask
@objc private func willForeground() { graceTask.end() }
```

Subscribe *before* sending — `events` is lazy-start. Runnable in the **03 Rich Content**, **06 Full reference**, and **07 Playground** examples — `Components/NewMessageNotifier.swift` packages all of the above (loop + grace window + `NotificationPolicy`) into one drop-in type, defaulting to `.whenBackgrounded` so it stays quiet while you're on the chat. Still a **local-only workaround** — no remote push yet (**coming soon**).

---

# Reference

## Configuration

```swift
PolyMessaging.initialize(.init(
    apiKey: "YOUR_CONNECTOR_TOKEN"
))
```

`apiKey` is the only required field; everything else has a working default.

| Field | Default | Description |
|---|---|---|
| `apiKey` | — (required) | Connector token from Agent Studio. Treat as a credential — never log it. |
| `environment` | `.us` | Production region (`.us` / `.uk` / `.euw`) or escape hatch (see below) |
| `hostIdentifier` | Bundle ID | `X-Host` for connector validation; auto-derived from `Bundle.main.bundleIdentifier` |
| `streamingEnabled` | `true` | `true`: agent replies grow token-by-token (ChatGPT-style). `false`: complete-message bubbles only. See [Streaming](#streaming) |
| `logLevel` | `.error` | `.none` \| `.error` \| `.warn` \| `.info` \| `.debug` |
| `heartbeatIntervalSeconds` | `nil` (30 s) | Override the heartbeat interval; server caps may overrule |
| `sessionTimeoutSeconds` | `nil` (600) | Override the idle-timeout (matches the backend's WebSocket idle timeout of 10 min) |
| `maxReconnectAttempts` | `nil` (10) | Override the reconnect cap |
| `webrtcToken` | `nil` | The web calling token for [`PolyVoice`](#voice-calling-polyvoice) — set it here once instead of repeating it at every `PolyVoice.call(...)` site. Ignored by chat; `nil` if this app doesn't place calls |

**Environments:**

- `.us` (default) — `messaging.us-1.poly.ai`
- `.uk` — `messaging.uk-1.poly.ai`
- `.euw` — `messaging.euw-1.poly.ai`
- `.cluster("name")` — any other named cluster, e.g. `.cluster("dev")` resolves to `messaging.dev.poly.ai`
- `.custom(restBaseURL:, wsBaseURL:)` — override both URLs entirely (proxies, local mocks)

Most apps don't need to set `environment` at all. Pass it only when targeting a non-US region or a non-production cluster:

```swift
// Run against the dev cluster instead of production US:
PolyMessaging.initialize(.init(
    apiKey: "YOUR_CONNECTOR_TOKEN",
    environment: .cluster("dev")
))
```

A fully-specified configuration (every value here has a working default — set only what you need to override):

```swift
PolyMessaging.initialize(.init(
    apiKey: "YOUR_CONNECTOR_TOKEN",
    environment: .us,                        // .us (default) | .uk | .euw | .cluster("dev") | .custom(...)
    hostIdentifier: "com.yourapp.ios",       // X-Host for connector validation; defaults to your bundle id
    streamingEnabled: true,                  // server streams agent replies as chunks
    logLevel: .error,                        // .none | .error | .warn | .info | .debug
    heartbeatIntervalSeconds: 30,            // server caps may overrule
    sessionTimeoutSeconds: 600,              // idle timeout before the session expires (matches backend ~10 min)
    maxReconnectAttempts: 10,                // reconnect budget before .failed
    webrtcToken: nil                         // set if this app also calls PolyVoice — see below
))
```

## Error handling

`send()` / `end()` throw `PolyError`. Use the convenience flags, or pattern-match the nested cases:

```swift
do {
    try await session.send(text)
} catch let error as PolyError {
    if error.isAuthError            { showError("Authentication failed") }
    else if error.isSessionExpired  { showError("Session timed out — start a new chat") }
    else if error.isRetryable       { showError("Connection issue — retrying…") }
    else                            { showError("Something went wrong: \(error)") }
}

switch error {
case .auth(.unauthorized):                  showError("Invalid connector token")
case .session(.sessionExpired):             showError("Session timed out")
case .transport(.networkError(let reason)): showError("Network: \(reason)")
default:                                     showError("\(error)")
}
```

Every case `PolyError` can throw, and when:

| Case | Fires when | Retryable |
|---|---|---|
| `.auth(.tokenAcquisitionFailed)` | the access-token request failed | no |
| `.auth(.unauthorized)` | the connector token was rejected (401/403) | no |
| `.session(.sessionCreationFailed(code))` | the server refused to create a session (`code` says why) | no |
| `.session(.unexpectedDisconnect(code:reason:))` | the socket dropped unexpectedly | yes |
| `.session(.maxReconnectAttemptsExceeded)` | reconnects were exhausted (terminal — offer `resume()`) | yes |
| `.session(.sessionExpired)` | the session idled out | no |
| `.session(.sessionEnded(reason:))` | the conversation ended | no |
| `.message(.deliveryFailed(draftId:))` | a sent message never confirmed after retries | no |
| `.message(.payloadTooLarge(maxBytes:))` | the message exceeds `max_message_size_bytes` | no |
| `.transport(.networkError(_))` · `.transport(.protocolError(reason:))` | a network / protocol-level failure | yes |
| `.invalidConfiguration(_)` | bad `Configuration` (e.g. empty token) | no |

Convenience flags: `isAuthError`, `isSessionError`, `isTransportError`, `isSessionExpired`, `isRetryable`.

## Connection states

`session.connection` is a `ConnectionStatus`. You rarely match it directly — `isConnected` / `isReconnecting` / `isFailed` / `isActive` and `session.failureReason` cover most UIs — but the full set:

| State | Meaning |
|---|---|
| `.idle` | not started yet |
| `.connecting` | opening the socket |
| `.open` | connected and ready (`isConnected`) |
| `.reconnecting(attempt:)` | transient drop; auto-retrying (`isReconnecting`) — show a banner |
| `.closing` | shutting down |
| `.closed(_)` | the server cleanly ended the session |
| `.failed(reason:)` | reconnect budget exhausted (`isFailed`) — offer manual `client.resume()` |

## Testing

Three scenarios catch most real-world breakage:

| Scenario | What it exercises |
|---|---|
| Toggle airplane mode mid-chat, then back | fast disconnect → `.reconnecting` → auto-resume on restore |
| Background the app > 5 min, then foreground | idle-timeout vs reconnect-and-resume paths |
| Kill and relaunch within the session timeout | `chat()` restores the conversation; `start()` always starts fresh |

## How it works

The SDK implements the [PolyAI Messaging API](https://docs.poly.ai/api-reference/messaging/introduction) — a WebSocket protocol — and manages the whole lifecycle: access-token → session → WebSocket → `REQUEST_POLY_AGENT_JOIN` → event exchange, with heartbeat, dedup, and cursor-based replay handled internally.

**Two consumer layers on one orchestrator. Both work in SwiftUI and UIKit** (`ChatSession`'s `@Published` properties are Combine, which UIKit consumes via `sink` — the only difference is the binding):

```
Your App (SwiftUI or UIKit)
  └─ ChatSession (ObservableObject)         ← observe @Published state; recommended
       └─ PolyMessagingClient                ← raw AsyncStream events; build your own state machine
            └─ Coordinator (actor)           ← SessionService · ChatService · ConnectionService
                                                HeartbeatService · NetworkMonitor
```

| Layer | When to use |
|---|---|
| `ChatSession` | **Recommended, both frameworks.** Observe `@Published` state; the SDK handles streaming assembly, dedup, delivery, resets. |
| `PolyMessagingClient` | Drive the raw `events` / `connectionStatus` / `sessionState` streams and build your own state. |
| `getConnection()` | Escape hatch — raw WebSocket frames. See [Raw transport](#advanced-raw-transport). |

**Reconnection is automatic:** drops the dead socket within ~100 ms of the OS reporting offline; exponential backoff with ±20% jitter (1s → 2s → … → 30s cap); transparent reconnect at the 2-hour mark and on session expiry; resumes from the last sequence (`cursor=<n>`) and dedups replayed events by `id`. When the reconnect budget is exhausted, `connection` becomes `.failed` — offer `client.resume()`.

**Design:** zero dependencies (Apple frameworks only); actor-based concurrency; hexagonal — transports and persistence behind protocols, so every layer is testable in isolation.

## Advanced: raw transport

`getConnection()` returns the live `Connection` for custom analytics or proprietary event types:

```swift
let raw = session.client.getConnection()

await raw.send(.userMessage(text: "Hello"))   // typed OutgoingEvent — SDK encodes JSON
await raw.send(.heartbeat)
try await raw.sendRaw(Data(#"{"type":"EVENT_TYPE_CUSTOM"}"#.utf8))   // arbitrary frame; throws .transport(.notConnected) if socket isn't open

Task { for await frame in raw.rawFrames { analytics.record(frame) } }   // tap every frame
```

`send(_:)` (typed `OutgoingEvent`), `sendRaw(_:)` (arbitrary JSON — `async throws`; throws `.transport(.notConnected)` if the socket isn't open), `rawFrames` / `messages` (`AsyncStream`s), `openEvents` / `closeEvents`.

> `sendRaw` bypasses delivery tracking, retry, and `local_id` correlation — no `.messagePending` / `.messageConfirmed`. Use it only when the managed `client.send(_:)` path doesn't fit.

## Dev tools (QA)

For internal builds, `DevSettings` (a public `ObservableObject`) is a UserDefaults-backed runtime `Configuration` builder — flip environment, streaming, logging, and other knobs without rebuilding. The **07-Playground** example pairs it with an on-screen diagnostics strip and event log, plus the [raw transport](#advanced-raw-transport) tap for protocol-level pokes. These are for development/QA — they bake in no credentials and aren't needed in production.

## Example apps

Examples live under [`Examples/`](Examples/), split by product — **[`Chat/`](Examples/SwiftUI/Chat/)**
(`PolyMessaging`) and **[`Voice/`](Examples/SwiftUI/Voice/)** (`PolyVoice`) — each mirrored across
**SwiftUI** and **UIKit**. Open any `.xcodeproj`, set your `apiKey`, and Cmd+R.

### Chat (`Examples/*/Chat`)

A 7-rung ladder — each level builds on the previous one; see its README for what's new.

| Level | What it adds | SwiftUI · UIKit |
|---|---|---|
| **01 Hello** | initialize, render, send | [SwiftUI](Examples/SwiftUI/Chat/01-Hello/) · [UIKit](Examples/UIKit/Chat/01-Hello/) |
| **02 Standard** | typing, suggestions, delivery, reconnect, end + start-new | [SwiftUI](Examples/SwiftUI/Chat/02-Standard/) · [UIKit](Examples/UIKit/Chat/02-Standard/) |
| **03 Rich Content** | attachments, link cards, `tel:` actions, Markdown | [SwiftUI](Examples/SwiftUI/Chat/03-RichContent/) · [UIKit](Examples/UIKit/Chat/03-RichContent/) |
| **04 Resilience** | offline banner, loading skeleton, terminal error + retry | [SwiftUI](Examples/SwiftUI/Chat/04-Resilience/) · [UIKit](Examples/UIKit/Chat/04-Resilience/) |
| **05 Handoff** | full live-agent ladder | [SwiftUI](Examples/SwiftUI/Chat/05-Handoff/) · [UIKit](Examples/UIKit/Chat/05-Handoff/) |
| **06 Full reference** | production resume + start-new flows | [SwiftUI](Examples/SwiftUI/Chat/06-FullReference/) · [UIKit](Examples/UIKit/Chat/06-FullReference/) |
| **07 Playground** | diagnostics, runtime config, streaming toggle | [SwiftUI](Examples/SwiftUI/Chat/07-Playground/) · [UIKit](Examples/UIKit/Chat/07-Playground/) |

### Voice (`Examples/*/Voice`)

A one-screen **tap-to-call** demo on the separate [`PolyVoice`](docs/PolyVoice.md) product — build a
`PolyCall`, observe its lifecycle, start / mute / end, with a speaker toggle. Set your connector token +
web calling token in the `PolyVoice.call(...)` block. Needs a **physical device** (the simulator can't carry
WebRTC media). See [Voice calling](#voice-calling-polyvoice).

| Level | What it covers | SwiftUI · UIKit |
|---|---|---|
| **01 Hello** | `PolyVoice.call()`, `call.states`, start / mute / end, speaker toggle | [SwiftUI](Examples/SwiftUI/Voice/01-Hello/) · [UIKit](Examples/UIKit/Voice/01-Hello/) |
| **02 CallKit** | the same call as a **system call** — CallKit wiring, lock-screen/AirPods controls, cellular-call hold | [SwiftUI](Examples/SwiftUI/Voice/02-CallKit/) · [UIKit](Examples/UIKit/Voice/02-CallKit/) |

## Requirements

| | Minimum |
|---|---|
| iOS | 15.0+ |
| Swift | 5.9+ |
| Xcode | 15.0+ |
| Dependencies | None — Apple frameworks only |

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) for the full text.

Copyright 2026 PolyAI Limited.
