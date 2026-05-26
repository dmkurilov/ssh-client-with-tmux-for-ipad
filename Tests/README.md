# Tests

## Usage

```
swift test                                # all tests
swift test --filter SSHConfigTests        # one module
swift test --filter IncludeTests          # one file
swift test --filter test_includeWithGlob  # one case
```


## Layout and local READMEs

The tests layout mirrors the source layout (see Principles below).

Each `Tests/<Module>Tests/` directory has its own `README.md` describing
what's specific to that module.


## Principles

### Mirror the source layout

One test file per source file. For example:

- `Sources/SSHConfig/Lexer.swift` → `Tests/SSHConfigTests/LexerTests.swift`
- `Sources/SSHConfig/Parser.swift` → `Tests/SSHConfigTests/ParserTests.swift`
- And so on.

The only exception: integration tests. For example,
`Tests/SSHConfigTests/IncludeTests.swift`.

### Test real code behavior, write integration tests, avoid mocks

Tests must help you refactor your code in the future. If you only
change an implementation, tests should not need to change.

For that very reason, avoid mocks (and dependency injection introduced
purely for testability). First, it forces you to rewrite mocks
whenever you refactor. Second, you may get false negatives — your
tests cover the mock, not the real code.

For example, `DiskFileLoader` reads data from disk. If you mock it,
you won't test the real code that loads data from disk, and you'll end
up writing a second piece of code that only mimics the real behavior —
code that won't help you in a future refactor. Instead, create a
temporary directory, put files there, and test the real code.

For the same reason, write integration tests. They check that the
whole module (or even the whole project) works as expected.

Some exceptions are possible. Spinning up a real server inside each
test, for instance, may bring complexity that isn't worth the fidelity
gain — think about testing timeouts via real `sleep`s. A carefully
scoped fake is acceptable in cases like that.

### Don't test everything

Every test is code that must be maintained.

Avoid testing pure value types directly. They should be covered
implicitly by the tests that exercise the code constructing them.

For the same reason, most internal functions should not be tested
directly. Their behavior is exercised by the externally available
functions that depend on them, which in turn are covered by behavioral
tests.

There are exceptions. Writing explicit tests for `Lexer.swift`, for
example, is much easier than expecting error-handling coverage to come
implicitly from higher-level tests.

### Write parallelization-safe tests

Avoid global fixtures.
