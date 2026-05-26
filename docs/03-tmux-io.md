# tmux IO — how bytes flow in and out

This doc captures the architectural Q&A we did after a stretch of
rendering bugs. It explains how a tmux `-CC` session actually works
end-to-end, and where our app sits in that picture. The audience is
us-six-months-from-now, debugging another rendering bug.

## 1. The pipeline at a glance

```
remote shell ──► pty ──► tmux server ──► SSH channel ──► our app ──► SwiftTerm
   (output)              (multiplexes        (one stream         (per-pane
                          all panes)          for all panes)      driver + view)
```

For a single tmux session there is **one SSH connection** and **one
tmux client process** (us). All N panes share that one byte stream.
tmux multiplexes them itself by tagging every chunk of output with the
pane it came from.

## 2. The control channel — one stream, two directions

We invoke `tmux -CC attach` on the remote. The SSH session's stdout
becomes a DCS-framed control stream; SSH stdin becomes a tmux command
channel.

**Server → us (notifications):**

- `%output %23 <bytes>` — pane `%23` produced these bytes
- `%window-add @4`, `%window-close @4`, `%layout-change @4 …`
- `%session-changed`, `%session-renamed`, `%client-session-changed`
- `%begin / %end / %error` — response brackets for commands we sent
- `%exit` — tmux is going away

**Us → server (commands, one per line):**

- `send-keys -t %23 -l 'l'` — literal byte to a pane
- `send-keys -t %23 Enter` — named key
- `new-window`, `kill-window`, `new-session -A -s ipad-1`
- `capture-pane -p -e -S - -t %23`
- `list-windows -F '…'`
- `display-message -p '<UUID>'` — our marker for response delimiting

The whole control stream is wrapped in DCS (`\x1bP1000p … \x1b\\`) so
that an outer terminal could in principle still display the wrapping
session. Inside the DCS envelope it's line-oriented.

## 3. How input reaches the shell

This is the part that's least obvious because **echo is the server's
job, not ours**. Trace one slow keystroke `l`:

1. **iPad UIKit** routes the key event to the active pane's
   `GatedTerminalView` (first responder).
2. **SwiftTerm** translates the key into raw terminal bytes — for `l`,
   `0x6C` — and calls `terminalDelegate.send(source:, data:)`.
3. **Our `TmuxSession.sendInput`** wraps the byte in a tmux command
   `send-keys -t %23 -l <byte>` and writes one line on SSH stdin. We
   never write raw key bytes onto the control channel — that channel
   is for tmux commands.
4. **tmux server** parses the line, looks up pane `%23`, writes the
   byte to the pane's pty master.
5. **Kernel pty layer (line discipline)** does two things in canonical
   mode (the shell default):
   - **Echo**: the `ECHO` termios flag bounces `0x6C` back onto the
     pty's read side immediately. The shell process is still blocked
     on `read()` and never saw the byte.
   - **Line buffer**: appends `0x6C` to the kernel's edit buffer.
     Shell still sees nothing.
6. **tmux pane reader** picks up the echoed byte from the pty's read
   side, advances its internal grid, and emits `%output %23 …` to
   every attached client. (Same notification, fan-out to all clients.)
7. **Our parser** decodes the bytes, hands them to the per-pane
   `TerminalDriver`, SwiftTerm renders the cell. We see `l`.

**Round trip per keystroke**: iPad → SSH up → server → kernel echo →
server → SSH down → iPad. On a high-latency link, the perceived typing
lag is exactly that round trip. iTerm2 papers over this with optimistic
local echo; we don't.

When you press **Enter**, line discipline finally **flushes** the
whole edit buffer (`l s _ - a l \n`) to the shell's `read()` in one
shot. Bash parses `ls -al`, fork+execs, the child writes to the same
pty, output streams back through the same `%output` path.

**Raw mode** (vim, htop, `claude`, `less`) flips the pty out of
canonical mode and disables echo. Each keystroke reaches the program
immediately and the program decides whether to repaint. The transport
is identical; only line discipline behavior changes.

## 4. The output side — server-side buffering

Each pane's output lives on the server, in two places:

- The **screen grid** — the visible region, sized to current cell
  dimensions (cols × rows).
- The **scrollback** — a per-pane history list, default ~2000 lines,
  configurable via `set -g history-limit`.

Critically, this state is owned by the tmux server, **not by any
client**. Programs running in panes write to the pty regardless of
whether anyone is attached. When you detach and reattach (or the SSH
drops and reconnects), nothing in the screen + scrollback is lost.
The new client gets:

- A fresh `%output` stream for new bytes from now on.
- For an existing-session attach, tmux replays the *active* window's
  current screen for free; other windows' panes are blank until you
  visit them. We work around this by running `capture-pane -p -e -S -`
  lazily on `.onChange(activeWindowID)` and feeding the result into
  the pane's `TerminalDriver` once.

Input that already reached the server is also persistent. Bytes
buffered in the kernel's pty edit buffer (typed but not yet `Enter`'d)
survive a client disconnect — they're sitting in kernel memory waiting
for a newline. Reattach and press Enter and the line goes through.

## 5. Races: notifications vs command responses

The protocol guarantees that command responses don't interleave with
notifications. After a `%begin t n f`, every line until the matching
`%end t n f` (or `%error`) is response payload — `%output` and other
notifications are queued by the server and emitted *after* the bracket
closes. So our parser never has to demux mid-response.

What we still have to solve is **which response belongs to which
command** when we send several. tmux's `(t, n, f)` triple is a number
and a flags word, not stable identifiers we control. We use a marker
trick instead: every `runCommand` is followed by `display-message -p
'<UUID>'`. We collect lines until we see our UUID echoed back, then
hand the prefix to the caller. The Task-chain in `TmuxSession`
serializes commands so only one is in flight at a time.

iTerm2 doesn't need the marker because it parses the bracket numbers
and trusts ordering — fine in practice, but our marker makes
mis-attribution literally impossible at the cost of one extra
round-trip per command. We picked correctness over latency here.

## 6. Sizing — what happens with multiple clients

A tmux session has one set of cell dimensions: `cols × rows`. With
multiple clients attached, tmux computes:

```
session.cols = min(client.cols)
session.rows = min(client.rows)
```

So if the iPad (120×30) attaches alongside the Mac (280×70), the
session shrinks to 120×30 — the **smallest client wins**. The Mac
renders into 120×30 and leaves the rest of its window blank. This is
why our force-detach UX matters: co-attaching shrinks the session for
everyone, so the iPad pre-detaches the Mac on connect.

`set -g aggressive-resize on` changes the rule per-window: each
window sizes to whichever client currently has it focused. Default
off because long-running TUIs that don't repaint cleanly on SIGWINCH
get unhappy.

**Scrollback is frozen at the width it was captured.** tmux doesn't
reflow history when the session resizes. Lines that scrolled off
during a 280-wide session stay 280 wide forever; when the iPad later
views them at 120 cols they soft-wrap or hard-truncate. Same in
reverse — lines captured during the iPad session are 120 wide when the
Mac later sees them, with whitespace to the right.

When a client detaches as last attached, the session keeps its last
size. Programs continue running and producing output at that size
into the now-unwatched pane. When the next client attaches, tmux
resizes down (or up) to the new minimum and SIGWINCHes every
foreground process group.

## 7. Server-stored vs client-fetched

Owned by the server, persisted independently of any client:

- Sessions, with current `cols × rows`.
- Windows, with layout trees (split tree, pane positions, pane sizes).
- Per-pane screen grid (visible cells at current dimensions).
- Per-pane scrollback (history-limited per `history-limit`).
- Pane-mode state (copy-mode, view-mode), pane titles, environment.

The client owns layout *intent* only via commands it sends
(`split-window`, `resize-pane`, `select-layout`); the server's layout
engine resolves them and broadcasts the result as `%layout-change` to
every attached client. Reattach from a different device and you see
the same layout because the server is the only owner.

Pushed automatically to every attached client (server → client, fan-out):

- All `%output` for all panes, every byte, all the time.
- Layout and lifecycle mutations (`%layout-change`, `%window-add`,
  `%session-changed`, `%window-pane-changed`, etc.).
- Visible region of the **active** window on initial attach.

NOT pushed automatically:

- Visible regions of non-active windows. The server has them, but
  doesn't replay until the client switches the active window. We hit
  this as the empty-non-active-pane bug.
- Scrollback for any pane. History is server-owned but only delivered
  on explicit `capture-pane`.

The client's only real choices are: **which historical content to
fetch** (`capture-pane` per pane, lazily), and **what to render** from
the firehose. Off-screen panes still consume `%output` because each
per-pane terminal emulator must stay current — we just don't draw
them.

### Per-pane subscriptions: not a thing for `%output`

There's no tmux server option that makes the `%output` stream
filterable per pane. The fan-out is unconditional: every attached
client receives every byte from every pane. Server config knobs like
`history-limit`, `aggressive-resize`, `pane-base-index`, etc. shape
*what* is captured and at *what size*, not *who hears about it*.

What does exist (and is sometimes confused for output subscription):

- **Format subscriptions** — `refresh-client -B '<name>:<target>:<format>'`
  (tmux 3.2+). The server emits `%subscription-changed` when a format
  string evaluated against a target changes. Useful for "notify me
  when pane `%23`'s title or `pane_current_command` changes." A
  separate event stream, not a filter on raw output.
- **`refresh-client -d`** — a server-side rate cap for the whole
  control client. Throttles the stream as a whole; doesn't filter it.
- **Pause mode** (tmux 3.2+) — server-side backpressure for slow
  control clients. The closest thing to a per-pane subscription, but
  the trigger is "client is falling behind," not "client only cares
  about pane X." Treated separately in section 8.

If you want "this client only cares about pane `%23`" semantics, the
client has to implement it itself by ignoring `%output` for the other
panes. The bytes still travel.

## 8. Pause mode — server-side backpressure

tmux 3.2+ ships a per-pane backpressure mechanism. When a control
client can't keep up with the `%output` firehose, the server pauses
output for the offending pane rather than buffer indefinitely and
fall further behind. We see this on the control channel as
`%pause %23` (and `%continue %23` when output resumes). Our parser
already turns these into `TmuxEvent.pause` / `.continuePane`; we just
don't act on them yet.

The trigger is the `pause-after` option, settable per pane:

```
set-option -p -t %23 pause-after 1
```

If a client falls more than that many seconds behind on `%output` for
that pane, the server stops sending output for it *to that client*.
The pane on the server keeps running normally — output is still being
captured into the pane's grid + scrollback. Only the push to the
lagging client is suspended. Other clients continue receiving output
as usual.

To resume, the client sends a `refresh-client -A` command naming the
pane (see tmux manpage for exact form). The server emits
`%continue %23` and resumes streaming. After resume, recent output
that scrolled past while paused is no longer in the live `%output`
stream — the client should follow up with
`capture-pane -p -e -S - -t %23` to backfill anything missed, the
same recovery path we already use after attach and on tab switch.

Why this matters for us:

- A pane running `tail -f /var/log/syslog` or a verbose build on a
  busy server can easily out-pace an iPad-over-cellular link. Without
  pause mode, every other pane on the same SSH connection gets
  head-of-line blocked behind that one firehose.
- Pause mode is the only mechanism tmux provides for dropping
  pressure from one pane without dropping the SSH connection or the
  whole tmux session. It's the closest thing to per-pane flow control
  the protocol has.
- A reasonable future improvement is to set `pause-after 2` on every
  pane on attach and wire the `%pause` / `%continue` events into the
  capture-pane recovery path. We're not there yet, but the events
  already arrive at the parser, so the missing piece is just the
  resume command + a refetch.

## 9. Three buffers, one byte stream

When a pane produces a long burst of output — think a 50k-line
`claude` run — the same bytes flow through three independent buffers.
They have different sizes and different lifetimes. Forgetting which
one is which is the source of the most common "where did my history
go?" confusion.

| Buffer | Owner | Default size | Lifetime |
|---|---|---|---|
| Pane grid + scrollback | tmux server | `history-limit` lines (default 2000) | Lives with the pane |
| SwiftTerm scrollback | our terminal view | ~500 lines (SwiftTerm default) | Lives with the view |
| Transcript file | our `TranscriptStore` | unbounded | Persists on disk |

What happens to a 50k-line burst, step by step:

1. The program writes to the pane's pty.
2. tmux's pane reader pulls bytes in. They land in the server's
   circular grid + scrollback. Once line 2001 arrives, line 1 is
   evicted server-side.
3. **Concurrently** — same bytes — tmux emits `%output %23 …` to
   every attached client. The eviction in step 2 doesn't affect step
   3; those bytes were already on the wire. **`history-limit` does
   not truncate live attached clients.**
4. Our parser feeds the bytes into the per-pane `TerminalDriver`.
   SwiftTerm's emulator updates its grid and pushes evicted lines
   into its own scrollback. Once SwiftTerm's circular buffer fills,
   oldest lines are evicted client-side.
5. If transcripts are enabled, `TranscriptStore` appends the same
   bytes to `Documents/transcripts/<host>-<session>-w<id>-pane<N>-<date>.log`.
   No size cap. This is the lossless record.

So when someone asks "is the content lost?" the right counter-question
is **lost where?**

- **In SwiftTerm's on-screen scrollback** — only the last ~500 lines
  are scrollable in the live view. Older content has been evicted
  from the view's buffer.
- **On the tmux server** — only the last 2000 lines are recoverable
  via `capture-pane`. Detach and reattach later: that's the upper
  bound on what you can pull back.
- **In the transcript file** — everything, byte-for-byte, until the
  user clears it.

### Practical implications

- **Bump `history-limit` on bootstrap.** It costs server RAM, has
  zero impact on the iPad, and meaningfully improves the
  "drop / reconnect later / scroll up" experience. Setting it to
  100000 is fine on any modern Linux box.
- **SwiftTerm's scrollback is the bottleneck for live scrollback.**
  If we want users to scroll past 500 lines without leaving the app,
  that's the knob to turn (SwiftTerm exposes a setter). Trade-off is
  iPad RAM per pane.
- **Transcripts are the only fully lossless record.** They're also
  the only place to recover content lost on *both* the server and
  SwiftTerm — e.g. a 50k-line Claude run where the server kept 2000
  and SwiftTerm kept 500. The Settings sheet's transcript browser is
  the recovery path for that case.

## 10. Color schemes — two layers, often confused

Almost every "why didn't my colors change?" question comes from
conflating two independent layers: the program emits color *codes*,
and the terminal owns the *palette*.

### Layer 1 — programs emit SGR codes

Every CLI program (bash, ls, vim, git, claude) colors its output by
writing ANSI SGR escape sequences. They never pick a pixel; they pick
a slot or an exact RGB:

```
\x1b[31m            ANSI red, slot 1 of the 16-color palette
\x1b[91m            bright red, slot 9 of the 16-color palette
\x1b[38;5;196m      256-color cube index 196
\x1b[38;2;255;0;0m  truecolor — exact RGB, bypasses palette
\x1b[m              reset to default
```

The first three are **indexed** ("use slot N"). The last is **direct**
("use this exact RGB"). That distinction explains everything that
follows.

### Layer 2 — the terminal owns the palette

The terminal emulator (SwiftTerm in our app, iTerm2 on Mac) keeps a
table that maps:

- ANSI slots 0–15 → 16 RGB values
- A 256-color cube (slots 16–255 → fixed RGB grid, rarely overridden)
- Default foreground / default background, cursor, selection

A "color scheme" in iTerm2 — or our `ColorSchemes` module — is just
this table. Switching schemes doesn't change a single byte on the
wire; it changes the *lookup*. Truecolor escapes skip the table
entirely.

### Why vim has "its own scheme"

Vim is just another program emitting SGR codes. `:colorscheme gruvbox`
changes **vim's mapping from syntactic categories to color
specifications** — what bytes vim emits, not how they're rendered.
A vim highlight rule looks like:

```
hi Comment   ctermfg=8    guifg=#928374
hi Function  ctermfg=214  guifg=#fabd2f
```

`ctermfg` = indexed color (palette slot). `guifg` = truecolor RGB.
Which one vim emits depends on `set termguicolors`:

- **`termguicolors` off** — vim emits indexed escapes. Final colors
  depend on both vim's colorscheme *and* the terminal palette.
- **`termguicolors` on** — vim emits truecolor escapes. Vim's
  colors become independent of the terminal palette.

Same pattern for every "themed" CLI: `bat`, `eza`, `delta`, `git
diff --color`, `claude`. Each ships a syntax-to-color map of its own
and writes through the same SGR pipe. `ls`'s equivalent is `LS_COLORS`
(env var); bash's prompt colors are inline escapes in `PS1`.

### What changes when you change what

| Action | Affects |
|---|---|
| Change our terminal scheme (or iTerm2's) | Bash prompt, `ls`, anything emitting indexed colors; vim's syntax if vim uses `ctermfg`; not vim with `termguicolors` |
| `:colorscheme gruvbox` in vim | Only vim's syntax highlighting |
| `set termguicolors` + truecolor scheme in vim | Vim's syntax becomes independent of terminal palette |
| Edit `LS_COLORS` | Only `ls`'s output |

This is why a user can change our app's scheme and see bash and `ls`
look different but vim look identical: vim's `:colorscheme` is a
separate axis we can't touch.

### Where tmux fits

tmux is its own terminal emulator in the middle. It parses SGR codes
from each pane, stores per-cell attributes in its grid, and re-emits
SGR codes to attached clients. The chain:

```
[bash | vim | ls]  ──SGR──►  [tmux server]  ──SGR──►  [our app]
       ↑                          ↑                       ↑
   per-app syntax map      passes through, but        SwiftTerm
   (vim colorscheme,       needs terminal-overrides     palette
    LS_COLORS, …)          for truecolor pass-through
```

The trap: tmux strips truecolor escapes down to 256-color
approximations unless told the outer terminal supports 24-bit. This
needs to be in our bootstrap or the user's `tmux.conf`:

```
set -g default-terminal "tmux-256color"
set -ga terminal-overrides ",*:Tc"
```

Without those, vim's `termguicolors` mode renders approximated colors
inside tmux even though our app would accept the real ones. Themed
TUIs that look fine in a bare ssh shell but "off" inside our app are
almost always hitting this.

### What our app controls

`ColorSchemes` + `ColorSchemeApply` write into SwiftTerm's palette —
layer 2. The user picking a scheme in our settings is functionally
identical to picking one in iTerm2. We don't and can't influence what
bash, vim, or claude emit; those are server-side. If a user wants vim
to look a particular way, that's a vim configuration problem, not
ours. We own only the palette that indexed escapes resolve against.

## 11. Where the bugs come from

The recurring failure mode is **assuming the client is the source of
truth**. It isn't — the server is. Every rendering bug we hit so far
traced back to one of:

- Replaying buffered bytes against a 0-column SwiftTerm view (fixed by
  binding only after `sizeChanged` reports a real width).
- Skipping `capture-pane` because the pane wasn't empty at attach time
  (fixed by `captureOnBootstrap` for existing-session attaches).
- Reusing a SwiftUI view across pane identity changes (fixed by
  `.id(paneID)` on `paneCell`).
- Mis-parsing OSC hyperlink terminators (`\x1b\\`) inside
  `capture-pane` payloads as DCS terminators (fixed by requiring a
  line-start position).
- Assuming non-active windows have content. They don't — tmux only
  replays the active window's screen on attach. We capture lazily.

Whenever a pane looks wrong, the question to ask first is: **what does
the server's grid + scrollback actually contain right now?** Run
`capture-pane -p -e -S -` and compare. If the bytes are there on the
server but missing in our view, the bug is in our pipeline. If the
bytes aren't on the server, look at the shell or the program in the
pane.
