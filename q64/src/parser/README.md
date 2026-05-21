# q64/src/parser

Lexer + parser + AST data types. Source → typed-by-shape syntax tree.

> **Status: not yet implemented.**

## Scope

**Owns:**
- Lexer (tokens, literals, comments, indentation-irrelevant whitespace).
- Parser (tokens → AST).
- AST data types (the syntax tree everyone downstream walks).
- Source maps (byte offset ↔ `(file, line, col)`).
- Error recovery — parse keeps going past errors to produce diagnostics
  for as much of the file as possible (LSP needs this).

**Does not own:**
- Name resolution → `typeck/`.
- Type inference → `typeck/`.
- Anything semantic — the parser knows shapes, not meaning.

## Inputs / outputs

- **In:** `.q` source bytes from disk, stdin, or LSP buffers.
- **Out:** an AST, a source map, and a list of diagnostics with `LEX*`
  and `PAR*` codes (per [`spec/diagnostics.md`](../../../spec/diagnostics.md)).

## External

None. Pure Zig.
