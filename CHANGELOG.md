# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Security

- **Lexer: fix out-of-bounds slice on a trailing backslash in a template
  middle/tail (crash / DoS).** A template `${…}`-segment ending with a backslash
  as the final source byte (e.g. `` `${1}\ ``) made `pos += 2` overshoot the
  source length, so the closing `src[start..pos]` slice panicked with an
  out-of-bounds index. `pos` is now clamped to the source length. Fixed in both
  the compiler and linter lexer copies. (Reachable; not mitigated by the 64 MB
  file cap.)
- **Module interop: cap resolution reads at 64 MB.** `readTextFile` (used to read
  `package.json` and candidate modules during ESM/CJS interop resolution) read
  with no size limit; a hostile or huge file could exhaust memory. It now uses
  the project's 64 MB limit and skips oversized files gracefully.
- **Lexer: prevent stack overflow / DoS on long comment runs.** `Lexer.nextInner`
  tail-recursed once per consecutive comment, so an input with a large run of
  `//` or `/* */` comments exhausted the native stack and crashed the process.
  It now iterates over leading comments. Fixed in both the compiler
  (`packages/compiler/src/syntax/lexer/lexer.zig`) and linter
  (`packages/linter/src/lexer.zig`) copies.
- **Parser: `async function` IIFE no longer produces broken output.** In
  expression position `async function () {}` was parsed as a declaration
  (`fn_decl`) instead of a function expression (`fn_expr`), so an async IIFE lost
  its wrapping parentheses (and, in the formatter, its leading ASI semicolon):
  `;(async function () {})()` emitted `async function() {}()`, which is
  semantically broken. Now parsed as `fn_expr` in both the compiler and linter
  parsers, yielding `(async function() {})();`. (Found by the newly enabled
  formatter suite.)
- **Parser: fix recursion-depth guard leak.** `parseBindingPattern` and
  `parseTsType` incremented the depth counter via `checkDepth()` without a
  matching decrement, so the counter grew across sequential declarations and
  raised a spurious `parser recursion depth exceeded` error on valid input past
  `max_depth` (2048). Both now restore the counter with
  `defer self.parse_depth -= 1;` (compiler + linter parsers).

### Performance

- **Reserve output buffers up front.** The compiler codegen buffer and the
  linter's line-based fallback formatter buffer now `ensureTotalCapacity(~1.5×
  source.len)` before emitting, avoiding repeated reallocations as output grows
  (matching the AST formatter, which already reserved). Output is unchanged.
- **`common.sourceRange` is now a single forward scan.** It previously called
  `sourcePosition` twice, rescanning the `[0..start]` prefix; it now walks to
  `start`, captures it, and continues to `end`. Output is unchanged.

### Fixed

- **Formatter: empty-statement and defensive-semicolon handling.** A bare empty
  statement (`;`) is now dropped instead of leaving a blank line
  (`;\nconst x = 1;` → `const x = 1;`), and a defensive leading `;` is dropped
  once the preceding statement is terminated (`const x = y\n;[1].forEach(...)` →
  `const x = y;\n[1].forEach(...);`). A genuine module-leading guard is still
  preserved (`;(async () => {})()` → `;(async () => {})();`).
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

### Build

- **Wire the package test suites into `zig build test`.** The suites under
  `packages/*/tests/` (~217 formatter, 46 linter, 3 common, 2 compiler, 1 cli
  tests) were compiled but never executed: they live in separate modules
  referenced via `comptime { _ = @import(...) }`, which only forces analysis, so
  their `test` blocks were never registered with the runner. Each suite now runs
  as its own test artifact, and the formatter suite gets a proper `harness`
  module import. This raises the executed test count from ~608 to ~874 (+266).

### Notes

- Enabling the formatter suite surfaced 11 pre-existing `semi_test.zig` failures.
  All are now resolved: 6 were stale expectations (the formatter correctly adds a
  trailing `;` with `semi: true`, cross-checked against the passing
  `tests/unit/formatter_leading_semi_test.zig`); the rest were the real bugs fixed
  above (async function IIFE, empty-statement / defensive-semicolon handling). No
  tests remain skipped.
- New regression coverage lives under `tests/unit/` (always executed) in addition
  to the now-running package suites.
- **Security audit notes.** An integer-overflow sweep of the lexers, parsers,
  codegen and formatter found no reachable overflow beyond the template slice
  fixed above — byte offsets are bounded by the 64 MB file cap and `u32`
  positions, and JSON/config `i64` values are `@max(_, 0)`-clamped before
  widening casts. Invalid UTF-8 input is memory-safe (the lexer advances
  byte-at-a-time and never slices out of bounds); strict UTF-8 *validation* is
  intentionally deferred since rejecting input would be a behavior change and the
  current handling is already safe. Relative imports legitimately use `../`, and
  resolution only `stat`s/reads metadata files (now size-capped) rather than
  echoing arbitrary paths, so no path-traversal read/write sink was introduced or
  found.
