# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Security

- **Lexer: prevent stack overflow / DoS on long comment runs.** `Lexer.nextInner`
  tail-recursed once per consecutive comment, so an input with a large run of
  `//` or `/* */` comments exhausted the native stack and crashed the process.
  It now iterates over leading comments. Fixed in both the compiler
  (`packages/compiler/src/syntax/lexer/lexer.zig`) and linter
  (`packages/linter/src/lexer.zig`) copies.
- **Parser: fix recursion-depth guard leak.** `parseBindingPattern` and
  `parseTsType` incremented the depth counter via `checkDepth()` without a
  matching decrement, so the counter grew across sequential declarations and
  raised a spurious `parser recursion depth exceeded` error on valid input past
  `max_depth` (2048). Both now restore the counter with
  `defer self.parse_depth -= 1;` (compiler + linter parsers).

### Performance

- **`common.sourceRange` is now a single forward scan.** It previously called
  `sourcePosition` twice, rescanning the `[0..start]` prefix; it now walks to
  `start`, captures it, and continues to `end`. Output is unchanged.

### Fixed

- **`incremental.loadCachedOutput` memory leaks.** Added `errdefer` so `code`,
  `map`, and `declarations` are freed when a later allocation fails.
- Removed dead `appendSuffix` helper in `packages/compiler/src/resolver/paths.zig`.

### Tests / Coverage

New edge-case tests added to the runnable unit suite (`tests/unit/`, executed by
`zig build test`). Each regression test was verified to **fail against the
unfixed code** before the fix and pass after:

- `tests/unit/lexer_test.zig` — compiler lexer:
  - long runs of consecutive line comments (200k) lex without stack overflow,
    asserting line tracking survives the loop (token lands on the expected line);
  - long runs of block comments (200k) lex without stack overflow;
  - a source consisting only of comments yields `eof`.
  - _Fail-first evidence:_ all three **segfault (stack overflow)** on the
    pre-fix recursive lexer.
- `tests/unit/parser_test.zig` — compiler parser:
  - 3000 sequential type annotations parse without a false depth error;
  - 3000 sequential binding patterns parse without a false depth error.
  - _Fail-first evidence:_ both raise `parser recursion depth exceeded` on the
    pre-fix parser.
- `tests/unit/regression_coverage_test.zig` — common + linter:
  - `common.sourceRange` matches the reference two-call `sourcePosition` across
    12 boundary cases (empty source, zero-length range, multiline, out-of-bounds
    clamping, and inverted `start > end`). Equivalence guard for the single-pass
    rewrite.
  - linter lexer handles a 200k comment run without stack overflow
    (_fail-first:_ segfaults on the pre-fix lexer).
  - linter parser parses 3000 declarations without a false depth error
    (_fail-first:_ raises `parser recursion depth exceeded` on the pre-fix
    parser).

### Notes

- The package test suites under `packages/*/tests/` (e.g. ~217 formatter tests,
  46 linter tests) are compiled but **not executed** by `zig build test`: they
  live in separate modules referenced via `comptime { _ = @import(...) }`, which
  only forces analysis, so their `test` blocks are never registered with the
  runner. New coverage here is therefore placed under `tests/unit/`. Wiring the
  package suites into the test runner is tracked separately.
