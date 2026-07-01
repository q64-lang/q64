# q64/src/fmt

The `q64 fmt` formatter.

> **Status: v0 implemented — reindent + canonical spacing.** The engine
> is `fmt.zig`; the CLI wiring (`q64 fmt [path] [--stdout|--check|--lint]`)
> is in `../main.zig`. See [`spec/q64-cli.md`](../../../spec/q64-cli.md)
> §"`q64 fmt`".

## What v0 does

v0 normalizes **layout that carries no meaning**, driven by the lossless
token stream the parser produces:

- **Indentation** — recomputed from bracket nesting, 4 spaces per level.
  Tabs and off-width indents are rewritten. Brackets *hug*:
  `print_all([` indents its children by one level, not two, and the
  matching `])` dedents once (see the indentation model in `fmt.zig`).
- **Spacing** — a canonical single-space style is applied *between*
  tokens: one space around binary operators and after `,`/`:`; tight
  `foo(x)`, `a.b.c`, `xs[0]`, `Vec<T>`, `|x|`, `-x`, `@stage`; spaces
  around a genuine `a < b`. The three tokens context alone can't resolve
  — `< >` (generic vs comparison), a leading sigil (`-x` vs `a - b`), and
  `|` (lambda vs bit-or) — are disambiguated from the **CST**, not from
  fragile token heuristics.
- **Vertical whitespace** — runs of blank lines collapse to one; leading
  blank lines are dropped; the file ends with exactly one newline.
- **Trailing whitespace** — stripped from every line (including inside a
  trailing line comment).
- **Comments** — line and doc comments are preserved and follow the
  current indent.
- **Atomic write-on-success** — the formatted bytes are written to a
  sibling temp file and renamed over the target, so a crash mid-write
  can never leave a truncated `.q` on disk (relevant to the ICE
  convention; see [`spec/diagnostics.md`](../../../spec/diagnostics.md)).

**Safety invariant.** The formatter only ever rewrites the trivia
*between* tokens, so the significant-token sequence is identical in and
out and `format` is idempotent. This is **enforced at runtime**: the
output is re-lexed and, if its token sequence differs from the input's (a
dropped space that would merge `let x` into `letx`), the original source
is returned untouched — the formatter can never corrupt code. Both
properties are covered by the tests in `fmt.zig` and were verified across
every `.q` file in the repo (0 token mismatches, 0 non-idempotent).

## Deferred / known limits

Future slices, each still inside the safety invariant:

- **Alignment** — no tabwriter, so hand-aligned columns are collapsed to
  single spaces rather than reproduced.
- **Trailing-comma normalization.**
- **Continuation-line indentation** for bracket-free wrapped lines (e.g.
  a `-> ReturnType` on its own line under a `fn` signature — v0 leaves it
  at the declaration's indent).
- **Line reflow / wrapping** long lines.
- **Generic call in expression position.** `Point<f32>(0.0)` (no
  turbofish) is parsed as comparisons (`<` / `>`) — the PAR040 ambiguity —
  so the formatter spaces it as `Point < f32 > (0.0)`. It faithfully
  reflects the parse; disambiguation is a parser concern, not the
  formatter's.

## Does not own

- Style configuration — there isn't any (gofmt/rustfmt convention).
- Multi-file refactoring — that's an LSP code-action concern.

## Inputs / outputs

- **In:** `.q` source files or directories (recursive), or stdin with
  `--stdout`. Parses with `parser/`.
- **Out:** reformatted source written in place (or to stdout with
  `--stdout`). A file with lexical/parse errors is **left untouched** and
  reported as `FMT001` — reformatting an unparseable buffer would risk
  mangling it. `--check` exits `64` when any file would change; `--lint`
  reports `FMT002` notes without modifying files.

## External

None. Pure Zig; depends only on the `parser` module.
