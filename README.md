# ssh-client-with-tmux-for-ipad

An iPad-only SSH client that delivers an iTerm2 + tmux `-CC` experience.

> **Status:** early development. The domain packages (`SSHConfig`,
> `TmuxCC`, `ColorSchemes`) are being built first on a Linux box;
> the iOS app target lives in an Xcode workspace that is scaffolded
> later on macOS.

## What this is (v1 scope)

- SSH client, not a local terminal.
- Full OpenSSH `ssh_config` grammar with `Include`, `Host`, `Match`,
  `ProxyJump`, token expansion.
- Password and public-key auth. Keys in iOS Keychain behind Face ID.
- iTerm2-style hotkeys, fully remappable. External keyboard first,
  on-screen mode with iSH-style extra key row optional.
- Tabs + splits via tmux `-CC`. User connects, then types
  `tmux -CC attach` manually (auto-attach is a later TODO).
- Color schemes, including `.itermcolors` import.
- Session transcript logging, exposed via the iPad Files app.
- URL scheme `ssh://user@host`.

See `docs/01-product-brief.md` for the complete v1 scope and
`docs/02-design-proposal.md` for stack decisions.

## Repository layout

```
Package.swift              -- single SPM manifest for all domain modules
Sources/
  SSHConfig/               -- OpenSSH ssh_config parser + resolver
  TmuxCC/                  -- tmux -CC protocol parser (planned)
  ColorSchemes/            -- .itermcolors importer + built-ins (planned)
  SSHCore/                 -- Citadel wrapper, connection pool (planned)
  TerminalKit/             -- SwiftTerm wrapper + input view (planned)
  OnboardingKit/           -- spotlight overlay (planned)
Tests/
  SSHConfigTests/
  ...
App/                       -- Xcode app target (scaffolded on macOS)
docs/                      -- product brief, design, conversation log
```

A single root `Package.swift` with multiple library products is used
(one target per module) rather than separate packages per folder. Same
modularity, simpler CI, one `swift test` to cover everything.

## Requirements

- **Client**: iPadOS 17+.
- **Build**: Swift 5.9+ (Xcode 15+).
- **Remote server**: tmux 3.2+ (for a complete `-CC` control-mode
  protocol). Older versions are unsupported.

## Building

```bash
swift build
swift test
```

The Xcode app target is added in a later step; pure-Swift domain
modules build and test without Xcode.

## License

[Apache 2.0](LICENSE).
