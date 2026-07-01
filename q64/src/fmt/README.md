# q64/src/fmt

The `q64 fmt` formatter.

> **Status: v0 implemented — a structural reindenter.** The engine is
> `fmt.zig`; the CLI wiring (`q64 fmt [path] [--stdout|--check|--lint]`)
> is in `../main.zig`. See [`spec/q64-cli.md`](../../../spec/q64-cli.md)
> §"`q64 fmt`".

## What v0 does

v0 normalizes **layout that carries no meaning**, driven by the lossless
token stream the parser produces:

- **Indentation** — recomputed from bracket nesting, 4 spaces per level.
  Tabs and off-width indents are rewritten. Brackets *hug*:
  `print_all([` indents its children by one level, not two, and the
  matching `])` dedents once (see the indentation model in `fmt.zig`).
- **Interior whitespace** — each run of spaces/tabs between two tokens on
  a line collapses to a single space (`fn   main` → `fn main`). This only
  ever turns a run of ≥1 spaces into exactly one; it never inserts a
  space where there was none, nor removes a lone one, so `a+b` stays
  `a+b` and no operator disambiguation is needed.
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

**Safety invariant.** The multiset of *significant* (non-trivia) tokens
is identical between input and output — v0 only ever rewrites the trivia
between tokens. So formatting cannot change a program's meaning, and
`format` is idempotent. Both properties are covered by the tests at the
bottom of `fmt.zig`, and were checked across every `.q` file in the repo.

## Deferred (not in v0)

These are owned by `fmt` but not yet implemented — each is a future
slice that stays inside the safety invariant:

- Full re-spacing: *inserting* a canonical single space around operators
  and after commas/colons, and *removing* spaces just inside brackets
  (`( x )` → `(x)`). v0 only collapses existing runs; it never adds or
  removes a space at a zero/single-space boundary.
- Alignment: v0 has no tabwriter, so hand-aligned columns are collapsed
  to single spaces rather than reproduced.
- Trailing-comma normalization.
- Continuation-line indentation for bracket-free wrapped lines (e.g. a
  `-> ReturnType` on its own line under a `fn` signature — v0 leaves it
  at the declaration's indent).
- Line reflow / wrapping long lines.

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
