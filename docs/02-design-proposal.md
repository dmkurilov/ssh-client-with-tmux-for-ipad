# Design proposal

Status: **approved 2026-04-17**. All open questions resolved — see
"Decisions" at the bottom.

## Language & UI
- **Swift**, iPadOS latest.
- **SwiftUI for chrome; UIKit for the terminal view.** The terminal pane
  needs a `UITextInput`-conforming `UIView` to handle IME, on-screen
  keyboard, predictive-text suppression, and hardware-key capture
  properly. Everything else (host list, tabs, settings, onboarding) is
  SwiftUI with `@Observable`.
- **Swift Concurrency** (`async`/`await`, actors) for SSH streams and
  tmux `-CC` parsing.

## SSH library — three realistic options

| Option | Pros | Cons |
|---|---|---|
| **Citadel** (pure Swift over SwiftNIO-SSH, MIT) | Apache/MIT clean, modern, no C bridging, plays nicely with async/await | Smaller ecosystem; we may need to contribute upstream fixes |
| **libssh2** via a thin Swift wrapper | Battle-tested, used by most iOS SSH apps | C bridging, older API, no async |
| **libssh** | Featureful | **LGPL** — awkward for App Store and self-distribution |

**Recommendation: Citadel / SwiftNIO-SSH.** License-clean, async-native.
If we hit a protocol gap we drop to libssh2 locally for that piece.

## Terminal renderer
- **SwiftTerm** (Miguel de Icaza, MIT). Handles VT/xterm, 256-color, true
  color, mouse modes, OSC 8 hyperlinks. Used by Secure ShellFish-class
  apps. Saves roughly 6 months of work.
- Wrap it in our own view so we keep full control over input routing,
  selection UX, and splits.
- TODO: evaluate a custom Metal renderer later if SwiftTerm becomes a
  perf ceiling.

## tmux `-CC`
- Custom Swift module. Protocol is small and line-based (`%begin`,
  `%end`, `%output`, `%window-add`, `%session-changed`, …).
- Model it as an actor that owns the SSH stream and publishes an
  `AsyncStream` of events.

## `ssh_config` parser
- Hand-rolled Swift parser.
- Needs: `Include`, `Match`, `Host`, token expansion (`%h`, `%p`, `%r`…),
  `ProxyJump`.
- ~1–2 days. Unit-testable in isolation.

## Storage
- **Keychain** for private keys with `.biometryCurrentSet` access
  control → Face ID gate, keys not extractable from backups.
- **SwiftData** (iPadOS 17+) for hosts, tabs, color schemes, session-log
  metadata.
- **Plain files in app sandbox** for session transcripts, exposed to the
  Files app via `UIDocumentPickerViewController` +
  `LSSupportsOpeningDocumentsInPlace`.

## Hotkeys & input
- `UIKeyCommand`-based registry, seeded with iTerm2 defaults, remappable
  via settings.
- On-screen extra key row as a SwiftUI accessory view (iSH-style).
- Trackpad: forward to tmux mouse mode when in keyboard mode; native
  `UIScrollView`-style panning when touch is active.

## Onboarding-in-place
- Custom SwiftUI spotlight overlay: dim background, cutout, callout
  bubble.
- Driven by a small `OnboardingStep` enum with `.anchorPreference` so
  each tip pins to a real view.
- Persist "seen" state in `UserDefaults`.
- Roll our own — existing OSS libraries (Instructions, etc.) are ObjC
  and dated.

## Project layout

Single `Package.swift` at the repo root with multiple library products
(one target per module), rather than one package per folder. Same
modularity, simpler CI, one `swift test` to cover everything. Can be
split into separate packages later if dependency isolation becomes
important.

```
Package.swift
Sources/
  SSHCore/        # Citadel wrapper, connection pool, ControlMaster-style sharing
  SSHConfig/      # ssh_config parser
  TmuxCC/         # -CC protocol
  TerminalKit/    # SwiftTerm wrapper + input view
  ColorSchemes/   # .itermcolors importer + built-ins
  OnboardingKit/  # spotlight overlay
Tests/
  SSHConfigTests/
  ...
App/              # Xcode app target — SwiftUI screens, DI, URL scheme handler
```

Domain modules are pure Swift where possible so `swift test` runs
without Xcode/UIKit. UI-layer modules (TerminalKit, OnboardingKit,
App) are macOS/iOS only.

## License
**Apache-2.0** works cleanly if every dep is MIT/BSD/Apache. Citadel,
SwiftTerm, SwiftNIO — all compatible. Avoids LGPL entanglement.

## Known risks / things to watch
1. **iOS backgrounds SSH sockets.** When the app suspends, TCP dies.
   We already chose "reconnect on open" — good. Worth validating early
   that tmux `-CC` reattach is seamless.
2. **App Store review later** may push back on custom key capture and
   "arbitrary command execution" framing. Fine for self-signed v1.
3. **Testing**: local `sshd` in Docker + scripted tmux sessions for
   integration tests. Unit tests for config / tmux / itermcolors parsers.

## Decisions (2026-04-17)

1. **Terminal renderer: SwiftTerm.** Custom Metal renderer remains a
   later TODO.
2. **SSH library: Citadel / SwiftNIO-SSH.** Pure Swift, MIT. Drop to
   libssh2 only if a protocol gap forces it.
3. **Deployment target: iPadOS 17.0.** Unlocks SwiftData, `@Observable`,
   improved Stage Manager APIs.
4. **Repo: GitHub, public from day one.**
5. **Product name: `ssh-client-with-tmux-for-ipad`** (same as the
   folder). Bundle ID and Info.plist copy derive from this.
