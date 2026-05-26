## TmuxCC

A parser for the tmux `-CC` control-mode protocol. Pure Swift,
Foundation-only, no SSH or I/O — bytes in, events out.

See `Tests/TmuxCCTests/FixtureTests.swift` for an end-to-end example.


## Pipeline

```
   bytes
     |
     v
 +------------+      +---------------+      +----------+
 | DCS frame  | ---> | Line splitter | ---> | Message  | --> [TmuxEvent]
 | (state M)  |      |               |      | dispatch |
 +------------+      +---------------+      +----------+
```

State is confined to the parser's DCS framing and a per-line buffer —
no session tracking, no command correlation, no SSH. Consumers feed
bytes (or strings) incrementally via `feed(_:)` and receive events.


## Design decisions

### Push shape, not async

`feed(_:)` is synchronous. It's trivial to unit-test, and wraps
cheaply into an `AsyncStream<TmuxEvent>` later when we have a
SwiftNIO/SSH byte producer. Slow networks are the actual bottleneck;
parser shape doesn't change that.


### Parser never throws

Malformed or unknown lines emit `.unknown(_)` rather than throwing.
The protocol evolves across tmux versions and we don't want a single
unrecognized event to tear down the connection. Consumers can log
and move on.


### DCS framing is opt-out, not mandatory

Control-mode output is wrapped in a DCS envelope
(`\x1bP1000p … \x1b\\`). Some captures and in-process streams have
already had the envelope stripped. `TmuxCCParser(expectDCSFraming:
false)` starts already-inside-DCS so those streams parse too.


### Layout strings are passed through, not parsed

`%layout-change` carries a nested-brace mini-language describing
pane geometry. Rather than encoding that grammar here, the event
exposes `layout`, `visibleLayout`, `flags` as raw strings. The module
that eventually renders splits can parse layouts then.


### Response bracketing, not correlation

The parser emits `.begin` / `.end` / `.responseError` / `.responseLine`
as separate events — it does not group them into request/response
pairs. Correlation needs the command number the caller sent, and
that knowledge lives in the SSH/command layer. Keeping it out here
mirrors SSHConfig's "resolver stays dumb" split.


### Octal-decoded `%output` data

tmux escapes control bytes and `\` in `%output` payloads as `\NNN`
(three octal digits). The parser decodes those into raw bytes and
attaches them as `Data` — the payload is opaque terminal output
(escape sequences, UTF-8, anything) that a terminal emulator
consumes. Malformed escapes pass through literally; real tmux never
emits them, but being permissive costs nothing.
