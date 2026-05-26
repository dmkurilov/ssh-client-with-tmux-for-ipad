# TODOs

Backlog of features that are clearly architecturally feasible but
not yet built. Each entry: the idea, why we'd want it, the rough
plan, and known open questions. Add new entries on top.

## SoftKeyboard v2 — symbols page, Ctrl modifier, F-keys, shifted digits

**Idea**: extend `App/Sources/SoftKeyboard.swift` (v1 shipped) with
the missing iOS-keyboard-equivalent surface area:

- **Symbols page** (`123` / `#+=` toggle): `! @ # $ % ^ & * ( )`,
  `[ ] { } < > = + ` ` ~`, etc. Mirrors iOS's standard 3-page
  layout.
- **Sticky `Ctrl` modifier**: tap `ctrl` to arm; next letter is
  `Ctrl-letter` (0x01–0x1A); state clears after one keystroke.
- **F-keys row**: `F1–F12` as an opt-in row (Settings toggle —
  default off). Sends `ESC O P` / `ESC O Q` etc.
- **Shifted number row**: when `⇧` is on, digits become `! @ #
  $ % ^ & * ( )`.

**Why**: v1 covers basic typing (lowercase letters, digits, common
punctuation, Enter, Backspace, arrows, prefix). To match iOS
keyboard input parity for general terminal use we need the
remaining symbols and modifiers. Power users running shells, vim,
git all need easy access to `{`, `}`, `\`, `~`, etc.

**Rough plan**:

1. Add a `Page` enum (`qwerty`, `numbers`, `symbols`) with a `123`
   / `#+=` button cycling through.
2. Layout each page via the same row helpers; reuse `keyButton`
   for non-letter rows.
3. Add `ctrlArmed` `@State`. When set, `letterButton` sends
   `(ascii & 0x1F)` instead of plain. Arms once, clears on use.
4. F-keys: gated behind a Settings toggle. Render as a 7th row
   when enabled.
5. Numeric shift: when `shifted` on `digitRow`, swap the labels and
   bytes for the `! @ # $ % ^ & * ( )` set.

**Open questions**:

- Tmux prefix is hard-coded to `Ctrl-B` in v1. Surface in Settings
  before or after this work? Same memory entry as binary upload's
  prefix discussion.
- F-keys: opt-in is friendlier; opt-out adds clutter. Keep as
  Settings toggle.
- Caps-lock state: `⇪` indicator currently only changes the shift
  glyph. Could persist across page changes — already does, since
  `shifted` / `capsLocked` are independent of `Page`. ✓

## Match remote terminal size on attach (font auto-fit)

**Idea**: when attaching to a session whose `cols × rows` is bigger
than what our default font would render in the iPad viewport,
auto-shrink the font so all of the remote content fits at 1:1 cell
dimensions instead of forcing tmux to resize down to iPad size.

**Why**: avoids the "old scrollback is 280 wide, new viewport is 120
wide" mismatch (see `03-tmux-io.md` §6). Programs running in panes
don't get SIGWINCH'd, history doesn't visually wrap, the iPad just
shows the same content the Mac was showing — at smaller text.

**Rough plan**:

1. On attach, fetch session dimensions via the first `%layout-change`
   or `display-message -p '#{session_width}x#{session_height}'`.
2. Compute target font size from `viewport / (cols, rows)` using
   SwiftTerm's font metrics. Pick the axis-fit strategy from a new
   setting.
3. Apply font to SwiftTerm before binding the driver, so the buffer
   replay happens at the right cell size.
4. Add a Settings toggle: "Match remote terminal size on attach" with
   options `Off | Fit cols | Fit rows`.

**Open questions**:

- Minimum readable font cap — below ~7pt we should refuse and fall
  back to default + standard resize. What's the actual floor on
  Retina iPads?
- Behavior when the session is *smaller* than our default. Probably
  do nothing (don't upscale font), but worth confirming.
- Interaction with full-screen mode toggle — viewport changes; we'd
  recompute on layout change.

## Drag panes between tabs (move-pane / break-pane)

**Idea**: let the user drag a pane from one tab strip into another, or
out into a new tab. Match iTerm2's pane-drag UX.

**Why**: a real workflow win. Today the only way to move work between
windows is to kill and recreate, losing scrollback and breaking the
running program. tmux supports this natively; we just don't expose it.

**Rough plan**:

1. Add a long-press-then-drag gesture to the pane container
   (`paneCell`). Show a drag preview with the pane's last visible
   line as a hint.
2. Drop targets: existing tab in the strip → `move-pane -s %src -t
   @dst` ; "new tab" zone → `break-pane -s %src` (tmux assigns a new
   `@id`).
3. Wire the resulting `%layout-change` for both source and
   destination windows into our existing layout-refresh path.
4. Because `.id(paneID)` is on `paneCell`, SwiftUI will preserve the
   same `SwiftTermView` and `TerminalDriver` as the pane re-parents.
   No manual state migration needed.

**Open questions**:

- What's the gesture story on iPad without dragging a tab off-screen?
  iTerm2 uses real OS-level windows; we can't.
- Drop on a *different host's* tab strip should be rejected (no tmux
  cross-server move). Need clear visual feedback.
- If the destination window has a different size, SIGWINCH redraw
  may flash. Acceptable, probably.
