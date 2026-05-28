# q64/src/fmt

The `q64 fmt` formatter.

> **Status: not yet implemented.**

## Scope

**Owns:**
- AST → formatted source text.
- A single canonical style (no user-configurable knobs in v0 — gofmt
  / rustfmt convention).
- Comment preservation (line and block).
- Trailing-comma normalization, expression-vs-statement layout,
  brace style, indentation.
- Atomic write-on-success — never leave a partially-written file on
  disk (relevant for the ICE convention; see
  [`spec/diagnostics.md`](../../../spec/diagnostics.md)).

**Does not own:**
- Style configuration — there isn't any.
- Multi-file refactoring — that's an LSP code action concern.

## Inputs / outputs

- **In:** `.q` source files or directories (recursive). Parses with
  `parser/`.
- **Out:** reformatted source written in-place (or to stdout with
  `--stdout`); diagnostics with `FMT*` codes for unparseable input.

## External

None. Pure Zig.
