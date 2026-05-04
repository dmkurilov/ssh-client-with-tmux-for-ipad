# TODOs

Backlog of features that are clearly architecturally feasible but
not yet built. Each entry: the idea, why we'd want it, the rough
plan, and known open questions. Add new entries on top.

## Hardware-keyboard-aware soft keyboard suppression

**Idea**: detect whether a HW keyboard is attached and use that to
gate the soft-keyboard toolbar button and the default `softKeyboard`
state. HW attached → no need for the toolbar control, and soft
keyboard should default to off. HW detached → restore the current
behavior (default on, toolbar visible).

**Why**: Magic Keyboard / Smart Keyboard Folio users currently see a
keyboard-toggle button they don't need, and have to tap it once to
hide the soft keyboard that pops up over their typing. Auto-detect
removes a manual step.

**Rough plan**:

1. Add a small `HardwareKeyboardObserver` (`@Observable`) backed by
   `GCKeyboard.coalescedKeyboard` from `GameController.framework`.
   Subscribe to `.GCKeyboardDidConnect` / `.GCKeyboardDidDisconnect`
   to keep `isAttached: Bool` current.
2. In `TmuxSessionView`: change `softKeyboard` default to follow
   `!observer.isAttached` on first appear; flip on disconnect events.
3. Hide the soft-keyboard toolbar button when `observer.isAttached`
   is `true` (or replace it with a small "HW" indicator).
4. Keep manual override: if the user explicitly toggles after
   attach/detach, respect their last choice for the rest of the
   session.

**Open questions**:

- Does iPadOS Simulator report HW keyboard correctly via `GCKeyboard`?
  Need to verify or document the workaround.
- Edge case: user docks/undocks Magic Keyboard mid-session — confirm
  the notification fires reliably.
- Should the override be remembered across sessions, or is "session
  scope" the right granularity?

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
