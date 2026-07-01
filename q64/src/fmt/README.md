# q64/src/fmt

The `q64 fmt` formatter.

> **Status: v0 implemented — reindent + canonical spacing + column
> alignment.** The engine is `fmt.zig`; the CLI wiring
> (`q64 fmt [path] [--stdout|--check|--lint]`) is in `../main.zig`. See
> [`spec/q64-cli.md`](../../../spec/q64-cli.md) §"`q64 fmt`".

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
- **Column alignment** (tabwriter) — a maximal run of consecutive lines
  at the same indent that share a *shape* has its columns aligned.
  Recognized tab-stops: a depth-0 assignment `=`, each element of a
  multi-element record literal or array literal (`Color { r: …, g: …,
  b: … }` and `[1, 2, 3]` grids align every column, including the closing
  `}`/`]`), and a trailing `//` comment.
  A blank line, an indent change, or a differently-shaped line breaks the
  run, so a column never spills across unrelated code. Runs operate on
  the canonically-spaced text, so alignment is idempotent (a re-format
  collapses the padding to single spaces, then re-adds it).
- **Continuation indent** — a wrapped line that begins with an
  infix/postfix lead (`->`, `|>`, `.`, `?.`, and binary operators that
  can't start a statement) indents one level under the line it continues,
  so a wrapped `-> ReturnType`, a `.method()` chain, or a `|>` pipeline
  reads as subordinate. Prefix-capable tokens (`-`, `!`, `~`, `&`, `*`,
  `<`) are excluded, so a real statement is never mis-indented.
- **Trailing commas** — a comma-list (call args, params, array, record,
  match arms) whose closing bracket sits on its own line is multi-line, so
  its last element gets a trailing comma (before any trailing comment).
  Single-line lists and comma-less groups (blocks, grouping parens) are
  left alone. This is the one transform that adds a token rather than only
  trivia — see *Safety* below.
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

**Safety.** Every transform except the trailing-comma pass rewrites only
the trivia *between* tokens; the trailing-comma pass may insert a comma
immediately before a closing bracket, and nothing else. This is
**enforced at runtime** by `outputIsSafe`: the output is re-parsed (so it
must still parse cleanly) and its significant-token sequence compared to
the input's, allowing *only* those inserted trailing commas. On any other
difference — a dropped space that would merge `let x` into `letx`, a stray
token, or output that no longer parses — the original source is returned
untouched, so the formatter can never corrupt code. `format` is also
idempotent. Both properties are covered by the tests in `fmt.zig` and
were verified across every `.q` file in the repo (0 unsafe fallbacks, 0
non-idempotent).

## Deferred / known limits

Future slices, each still inside the safety invariant:

- **Call-argument grids** — column alignment covers record and array
  literals; the same treatment for multi-line call arguments is a natural
  extension (deliberately scoped out for now to avoid over-aligning
  ordinary calls).
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
