# TmuxCCTests

Fixtures live in `Fixtures/` and are copied into the test bundle by
`Package.swift`. Load via
`Bundle.module.url(forResource:withExtension:subdirectory:)`.

## Capturing a new fixture

iTerm2's tmux integration hijacks `-CC` streams, so you cannot
capture the raw protocol in an iTerm2 window. Two known-working
recipes:

### macOS (needs `brew install expect`)

```bash
unbuffer -p tmux -L cc-record -CC new-session -s cc-record \
  > ~/tmux-cc-fixture.log 2>&1 <<'EOF'
new-window
split-window -h
send-keys -t cc-record:0.0 'echo hello' Enter
kill-server
EOF
```

### Linux (uses util-linux `script`)

```bash
script -qc 'tmux -L cc-record -CC new-session -s cc-record' \
  ~/tmux-cc-fixture.log <<'EOF'
new-window
split-window -h
send-keys -t cc-record:0.0 'echo hello' Enter
kill-server
EOF
```

`-L cc-record` puts tmux on a private socket — important, because
without it the scripted `send-keys` and `kill-server` can interfere
with (or terminate) your real tmux sessions.

### Writing the test

Captured files may include a few heredoc-echo lines at the top and
may or may not contain the `\x1bP1000p … \x1b\\` envelope bytes,
depending on how the PTY forwarded them. Construct the parser with
`TmuxCCParser(expectDCSFraming: false)` and the leading non-`%`
lines are parsed as harmless `.responseLine`s you can skip or assert
against.
