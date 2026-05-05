# UI vision

Canonical design for the app's two screens. Supersedes ad-hoc UI
decisions made earlier in development. Where current code disagrees
with this doc, the doc is right and the code is the TODO.

## 1. Two screens

- **Main screen**: hosts and SSH keys. App-wide settings live here.
- **Session screen**: the terminal. Same layout for SSH and tmux
  modes; SSH hides the tab/pane affordances that don't apply.

## 2. Main screen

```
st      Hosts:     <add host>
        host1
        host2

        SSH keys:  <add key>
        key1
        key2
```

- `<add host>` → import from `ssh_config` or add manually.
- `<add key>` → import from Files or generate new.
- Tap a host → host detail (today's view) + edit button for the
  display title.
- Tap a key → title (with edit), `.pub` content (copyable), and a
  read-only list of hosts using it.
- `st` → Settings sheet.

### Settings sections

- **Appearance**: color scheme picker (per-host override + global
  default), font size, scrollback cap (default 100k), light/dark/
  system for app chrome (terminal palette stays driven by the
  scheme).
- **Debug**: existing debug-logging toggle + browse + reset.
- **Transcripts**: existing per-pane transcript browser + manage.

Settings is *not* available from the session screen.

## 3. Session screen

```
<back              < session name >  <edit>          fs  tb  kb
─────────────────────────────────────────────────────────────────
**tab1** | tab2 | tab3 | tab4   +
─────────────────────────────────────┬──────────────────────────
pane1 content              [x ...]   │ pane2          [x ...]
                                     │                       <->
                                     ├───────────────────────
                                     │ pane3 (vim)    [x ...]
─────────────────────────────────────┴──────────────────────────
```

### 3.1 Top toolbar

- **Left**: `<back` returns to main screen.
- **Center**: `< session name >` plus an explicit `<edit>` rename
  button. Long-press on the name also opens rename (kept for power
  users).
- **Right** (in order): `fs`, `tb`, `kb`.

`fs` toggles app-level fullscreen (status bar hidden, top toolbar
hidden, panes get all the real estate). `tb` toggles the tab strip;
hidden in SSH mode. `kb` is the keyboard-mode picker (§4).

When fullscreen is on and the toolbar is hidden, a near-transparent
`<->` symbol shows in the top-right pane corner as an exit
affordance for users who forgot the shortcut.

### 3.2 Tab strip

`**active** | other | other | other   +`

- `+` creates a new tab (`new-window`).
- Each tab carries an `x` close button.
- Closing the last pane in a tab closes the tab.
- No hotkey for closing a tab — only `x` or implicit close.
- Active tab is bolded.
- Long-press a tab → rename.
- Hidden entirely in SSH mode.

### 3.3 Pane area

Panes match tmux's layout exactly. The **active pane renders at full
brightness; inactive panes render at ~80%** via a per-pane alpha
overlay. No accent border, no palette manipulation — just a render
dimming so cell colors stay faithful.

Panes are resizable by dragging the divider between them (sends
`resize-pane`).

### 3.4 Pane control `[x ...]`

Top-right corner of each pane. Near-transparent at rest, opaque on
hover/tap. Three responsibilities:

- The strip itself is a **drag handle**: drag to another location
  within the tab → `move-pane`; drag onto a tab in the strip →
  `move-pane -t @dst`; drag onto `+` → `break-pane`.
- `x` closes the pane (`kill-pane`).
- `...` menu:
  - Split pane vertically
  - Split pane horizontally
  - Move pane to … (target picker)
  - Select all
  - Copy
  - Paste
  - Insert image to current working directory *(§3.5)*
  - Clear buffer

**In SSH mode** the menu is reduced to: Select all, Copy, Paste,
Insert image, Clear buffer. The drag handle and `x` are inert / not
shown — there's nowhere to drag a single pane and no other panes to
leave.

Selection auto-copies to the system clipboard (iTerm2-style).
Long-press inside the pane begins touch-driven selection. Long-press
is reserved exclusively for selection — it never shows the keyboard
or triggers other gestures.

### 3.5 Insert image / `⌘V`

Both routes upload to the active pane's **current working
directory**. No directory picker.

- `⌘V` with a non-text clipboard → modal sheet asks for a
  *filename only*. Extension is auto-detected from the pasteboard
  UTI via `UTType.preferredFilenameExtension`
  (`public.png` → `.png`, `public.heic` → `.heic`,
  `public.jpeg` → `.jpeg`, `com.adobe.pdf` → `.pdf`, …) and
  appended automatically. Default basename: `paste-<timestamp>`,
  or the source filename if Files preserved it. User edits, taps
  Upload, file is sent over SFTP into the pane's CWD.
- `...` → *Insert image to current working directory* → same
  sheet, same flow.
- `⌘V` with text-only clipboard → existing paste-as-keystrokes.

CWD detection:
- **tmux mode**: `pane_current_path` from tmux.
- **SSH mode**: shell integration (`PROMPT_COMMAND` setting
  `OSC 7`); fall back to a one-shot `pwd` exec at upload time if
  unavailable.

## 4. Keyboard

### 4.1 Software keyboard layout

```
[ special keys ]                                  [ hide ]
[ standard iOS keyboard                                  ]
```

Special keys row: `Esc`, `Tab`, `Ctrl`, arrow cluster, `|`, one-tap
tmux prefix (default `Ctrl-B`). No F-keys by default; opt-in.

### 4.2 Showing the keyboard

**Single-finger taps in a pane never show the keyboard.** This is
deliberate — accidental taps during scroll or selection in other
SSH clients ruin the gesture; we don't want that.

Routes to show:

- `kb` toolbar button (mode picker).
- Auto mode + no HW keyboard → keyboard appears automatically.

Long-press is reserved for selection.

### 4.3 `kb` modes

Three modes; user picks via the `kb` button:

- **Auto** (default)
  - HW present → SW always hidden.
  - HW absent → SW shown by default. Tapping the keyboard's hide
    button flips the effective state to hidden for the rest of
    this session attach. To re-show, tap `kb` and switch to
    *Forcefully shown*.
- **Forcefully hidden** — SW hidden regardless of HW. Hide button
  is a no-op.
- **Forcefully shown** — SW shown regardless of HW. Hide button
  dismisses the keyboard one-shot; the mode itself doesn't change.

HW detection: `GCKeyboard.coalescedKeyboard` from the
`GameController` framework (see `04-todos.md`).

## 5. Hotkeys

| Shortcut | Action |
|---|---|
| `⌘F` | Search in scrollback (find inline) |
| `⌘⇧F` | Toggle app-level fullscreen |
| `⌘⇧Enter` | Toggle pane zoom — `resize-pane -Z` (SSH: no-op) |
| `⌘⇧T` | Toggle tab strip in fullscreen |
| `⌘D` | Split pane vertically |
| `⌘⇧D` | Split pane horizontally |
| `⌘W` | Close pane |
| `⌘T` | New tab |

No hotkey for closing a tab — only `x` or implicit close.

`⌘⇧Enter` is **pane** zoom (one pane fills the tab area; tab strip
stays visible), distinct from `⌘⇧F` which is **app-level**
fullscreen. Don't confuse them.

## 6. Connecting state

The session screen mounts immediately on tap-host, but is mostly
disabled: panes / tabs / `+` / `x` / `fs` / `tb` / `kb` are inert.
Only `<back` is active.

The pane area shows a centered step list:

```
Resolving DNS…
Authenticating…
Attaching session ipad-1…
```

Each step transitions ✓ when complete. On error, surface inline
with Retry / Cancel.

## 7. Disconnection

We do not detect SSH/tmux disconnects. When the underlying
connection drops, the session screen freezes — no reaction to
keystrokes, no banner, no auto-reconnect. User backs out via
`<back` and reconnects manually. iTerm2-style.

Intentional for v1. Auto-reconnect is its own workstream; we'd
rather ship something that doesn't lie about connection state.

## 8. Search

`⌘F` opens an inline search bar at the top of the active pane.
Matches highlight in scrollback, `n` / `N` cycle, `Esc` or `⌘F`
again closes. Operates on SwiftTerm's local 100k-line scrollback;
does not query tmux.

## 9. Deliberately absent (v1)

- **Status info on panes** (host, current command, lag).
- **Bell / activity indicators on tabs.**
- **Per-pane accent border for focus.** Brightness contrast
  replaces it.
- **Multi-window / Stage Manager.**
- **Tab-close hotkey.**
- **Auto-reconnect / disconnect detection.**
- **Settings on session screen.**
