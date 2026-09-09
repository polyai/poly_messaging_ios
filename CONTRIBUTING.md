# Contributing to PolyMessaging iOS SDK

Contributions are welcome. Please ensure the SDK builds and the test suite passes before opening a pull request.

## Development setup

### Prerequisites

- macOS with Xcode 15.0 or newer
- Swift 5.9+ (bundled with Xcode 15)
- [xcodegen](https://github.com/yonaskolb/XcodeGen) (only needed if you touch the example apps): `brew install xcodegen`

### Getting started

```bash
git clone https://github.com/polyai/ios-sdk.git
cd ios-sdk
swift build
swift test
```

The SDK has **zero third-party dependencies** — Apple frameworks only. Do not add Swift Package dependencies to `Package.swift`.

## Running tests

```bash
swift test               # SDK unit tests
scripts/build-all.sh     # build every example app (slow — full ladder)
```

To work on a single example:

```bash
cd Examples/SwiftUI/Chat/06-FullReference
xcodegen generate
open *.xcodeproj
```

## Project structure

- `Sources/PolyMessaging/` — the SDK
  - `Public/` — public API surface (only types here are part of the contract)
  - `Internal/` — implementation (Adapters, Helpers, Ports, Services, Wire)
  - `PolyMessaging.swift` — top-level facade
  - `PolyMessagingClient.swift` — lower-level client used by `ChatSession`
- `Tests/PolyMessagingTests/` — XCTest suite
- `Examples/SwiftUI/` and `Examples/UIKit/` — the feature ladder (`01-Hello` … `07-Playground`)
- `scripts/` — `build-all.sh`, `verify.sh`, `run-uitests.sh`

If you change the SDK, mirror the change across the SwiftUI and UIKit example ladders, and keep `README.md` in sync.

## Code style

- Follow the existing Swift style — 4-space indent, types in `UpperCamelCase`, members in `lowerCamelCase`.
- Every new `.swift` file must start with `// Copyright PolyAI Limited` followed by a blank line.
- Public types and methods need a doc comment (`///`) describing **why** to use them, not just what they do.
- Don't introduce comments that simply restate the code. Only comment non-obvious invariants.
- The SDK is `@MainActor` where it touches `ChatSession` state — preserve those annotations.
- Never log connector tokens or session identifiers.

## Commit conventions

This repository uses [Conventional Commits](https://www.conventionalcommits.org/) for commit messages. Versioning and `CHANGELOG.md` are maintained by hand when cutting a release.

| Type       | Effect on version (pre-1.0)              |
|------------|------------------------------------------|
| `feat:`    | Minor bump (`0.X.0`)                     |
| `fix:`     | Patch bump (`0.0.X`) — pre-1.0 minor bump is disabled |
| `feat!:` / `BREAKING CHANGE:` | Minor bump (pre-1.0); major bump post-1.0 |
| `docs:`, `chore:`, `test:`, `refactor:`, `style:`, `ci:`, `build:`, `perf:` | No release |

Examples:

```
feat: add typing-indicator throttling to ChatSession
fix: drop dead WebSocket immediately on NWPath offline
docs(examples): keep 04-Resilience README in sync with code
chore(release): 0.5.0
```

## Releases

Releases are cut manually:

1. Conventional commits land on `main`.
2. To cut a release, bump the version in all four places — `Sources/PolyMessaging/Public/Version.swift`, `PolyMessaging.podspec`, `PolyVoice.podspec`, and a new `CHANGELOG.md` entry — then tag `vX.Y.Z`. The two podspecs are released together and always carry the same version, because `PolyVoice` depends on `PolyMessaging` at an exact version.
3. Publish the CocoaPods, **in this order** (requires a one-time `pod trunk register`):

   ```bash
   pod trunk push PolyMessaging.podspec
   pod trunk push PolyVoice.podspec   # depends on PolyMessaging — push only once the above is live
   ```

   The `:tag` in each podspec must match the `vX.Y.Z` tag, so push only after tagging. `PolyVoice`
   will fail validation until the `PolyMessaging` push has propagated to the trunk index.
4. The version literal in `Version.swift` is the single source of truth — it is the User-Agent the SDK sends and the version surfaced to example apps. Both podspec versions must mirror it exactly. **Bump them only when cutting a release, never in feature PRs.**

## Verifying changes before opening a PR

```bash
swift build            # SDK compiles
swift test             # tests pass
scripts/build-all.sh   # every example app builds (only if you touched Examples/ or public API)
```

For UI/example changes, open the relevant `Examples/<platform>/<NN-Name>` project and exercise the feature in the simulator.

## Scope boundaries

- **No third-party dependencies.** This package is intentionally dependency-free.
- **Don't edit `Sources/PolyMessaging/` to make integration "easier"** — the public API is the contract; integration changes belong in the consuming app.
- **Keep credentials out of source.** Connector tokens are set via `PolyMessaging.initialize(...)` at runtime, never committed.

