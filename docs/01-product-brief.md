# Product brief — SSH client with tmux for iPad

## One-liner
An SSH client for iPad (not a terminal emulator like iSH) that delivers an
iTerm2 + tmux `-CC` experience, with external-keyboard-first UX, configurable
iTerm2-style hotkeys, splits/tabs, and color schemes.

## Non-goals
- Being a local shell / terminal emulator (no local bash, no BusyBox).
- Running on iPhone (screen too small) or Mac (iTerm2 already exists).

## Target platform
- **iPad only.**
- **Latest iPadOS** for v1. Backwards compatibility considered later.
- Distribution in v1: **self-signed** while in development. App Store is a
  later question.

## v1 feature decisions

### SSH
- Full OpenSSH `ssh_config` grammar (`Include`, `Match`, `ProxyJump`,
  token expansion, etc.).
- Auth methods in v1: **passwords** and **public keys**.
  - Passphrase-encrypted keys: consider later, not v1.
  - Hardware keys / `ssh-agent` forwarding / FIDO / etc.: not v1.
- `known_hosts` with TOFU prompts on first connect and mismatch warnings.
- Port forwarding / SOCKS / X11: **TODO — out of v1.**
- Mosh: **not in v1.**
- SSH connection sharing (ControlMaster-style): **yes**, multiple tabs
  reuse one TCP connection.

### Tmux integration
- Start simple: user connects, then manually types `tmux -CC attach`.
  TODO: add auto-attach later.
- Splits: simplest possible implementation first. TODO: revisit native
  SwiftUI splits mapped to tmux splits.
- Terminal feature parity target: **iTerm2 over plain SSH** — true color,
  256 color, italics, OSC 8 hyperlinks, mouse mode, copy-mode, scrollback,
  search.

### Keys & storage
- Private keys in **iOS Keychain**.
- **Face ID required** before unlocking keys (`.biometryCurrentSet`
  access control).
- iCloud sync of configs/keys: **TODO — not v1.**

### Input & UX
- **External keyboard primary.** iTerm2 default hotkeys, fully
  reconfigurable like iTerm2's keymap.
- **On-screen mode** toggleable in settings. When enabled, show an
  iSH-style extra key row (Esc, Ctrl, Tab, arrows, Fn).
- **Trackpad**: when in keyboard mode, forward mouse events like iTerm2
  (tmux mouse mode, vim, etc.). When fingers are on screen (or on-screen
  mode is active), behave like a native iPad app — Notes-style scrolling.
- **Session persistence**: if iOS suspends the app, silently reconnect
  and re-attach tmux when the user reopens.
- **Paste safety**: confirm before pasting multi-line content.
- **URL scheme**: `ssh://user@host` launches the app.

### Color schemes
- Ship a curated set of nice color schemes.
- **Import `.itermcolors`** files from iTerm2.

### Logging
- Log every session transcript to the app sandbox.
- User manages logs (export, delete) via the iPad Files app.

### Configuration
- v1: import `ssh_config` / key files from the iPad Files app.
- Offline config editor with syntax highlighting: **TODO — not v1.**

### Onboarding
- **Onboarding-in-place**: coach marks / spotlight overlays that point at
  specific UI regions and explain what the user can change.

### Distribution & license
- v1: **self-signed** for development.
- License: **Apache 2.0** (preference, open to alternatives).
- Monetization: **free for everyone.**
