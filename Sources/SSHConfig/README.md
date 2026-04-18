## SSHConfig

A parser and resolver for OpenSSH `ssh_config(5)` files. Pure Swift,
Foundation-only, no platform dependencies — runs anywhere Swift runs.

See `Tests/SSHConfigTests/IncludeTests.swift` for usage examples.


## Pipeline

```
   text
     │
     ▼
 ┌───────┐  lines        ┌────────┐                  ┌────────┐
 │ Lexer │ ─────────────▶│ Parser │ ────[Block]────▶ │Resolver│
 └───────┘               └────────┘                  └────────┘
                             ▲                             │
                             │ Include                     ▼
                             │                      ResolvedConfig
                        ┌──────────┐                       │
                        │FileLoader│                       ▼
                        └──────────┘                TokenExpander
                                                     (per-keyword,
                                                      caller-driven)
```

Consumers give it the text of a config (or a file URL), then ask for the
effective settings that apply to a given target host. The library does
not make network connections itself; it produces a `ResolvedConfig` that
an SSH client can read.


## Design decisions

### First-match-wins, but nothing is thrown away

OpenSSH's rule is: within a single resolution, the first value seen for
a keyword wins. Rather than bake that rule into the resolver and lose
data, `ResolvedConfig.values` stores **every** matching value in
encounter order, keyed by the lowercased keyword. Accessors choose
semantics:

- `firstArg("port")` → first-wins.
- `allArgs("identityfile")` → accumulates, for keywords where OpenSSH
  intentionally keeps multiple values (identity files, forwards, send-
  env entries).

This keeps the resolver dumb and lets callers (or future helpers) pick
per-keyword policies without reparsing.


### `Include` is resolved during parse, not at resolution time

Includes are expanded while building the `[Block]` array, not each time
someone calls `resolve(host:)`. Rationale:

- Resolution is a hot path; parse is a cold path. Do the file I/O once.
- The included content naturally fits into the same `[Block]` stream.
- Cycle detection is straightforward with a `Set<URL>` threaded through
  recursive calls.

Semantics match OpenSSH:

- Relative paths resolve against the including file's directory, or
  `~/.ssh/` if the including content has no source URL (e.g. parsing a
  string literal).
- `~/` expands to the loader's `homeDirectory`.
- Path components with `*` or `?` are expanded via filesystem listing.
- Missing includes are silent no-ops (OpenSSH behavior).
- Cycles throw `SSHConfigError.includeCycle`.
- Depth is capped (default 16) to stop runaway recursion.
- When an `Include` appears inside a `Host`/`Match` block and its own
  content starts with global directives, those directives are folded
  into the current block; any `Host`/`Match` blocks inside the include
  are appended as top-level blocks and the outer context resets.


### Pattern matching

One glob implementation in `Patterns.swift` handles both `Host` lines
and Match-keyword pattern lists. It supports `*` (zero-or-more) and `?`
(exactly-one) with OpenSSH's negation rule via `!` prefix:

- In a pattern list, any matching negated pattern forces an overall
  miss, even if other non-negated patterns would match.
- A list containing only negations never matches anything.
- Matching is case-insensitive (hosts lowercased before compare).


### `Match`

Supported today: `all`, `host`, `originalhost`, `user`, `localuser`.

`exec`, `final`, `canonical`, and other keywords parse into
`MatchCondition.unsupported(keyword:argument:)` and evaluate as
"does not match." This lets a file mentioning `Match exec` parse
without errors; the block simply never applies. See code TODOs.


### Token expansion as a separate, opt-in pass

OpenSSH expands `%`-tokens only on certain keywords (the set differs
per keyword). Rather than encode that table, `TokenExpander.expand(_:
with:)` is a raw string transform the caller invokes at the point of
use — e.g., when constructing a `ProxyCommand` string before handing
it to the shell runner. `TokenContext` carries everything the expander
might need (local/remote user, hosts, port, home dir).
