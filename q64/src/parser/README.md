# q64/src/parser

Lexer + parser + CST + AST views. Source bytes → lossless concrete
syntax tree → typed AST views over it.

> **Status: scaffolding in progress.** `cst.zig` and `SyntaxKind`
> land first; lexer, parser, and AST views follow.

## Scope

**Owns:**

- **Lexer** — bytes → tokens. Trivia (whitespace, comments, newlines)
  preserved as token kinds, not discarded.
- **Parser** — tokens → CST. Recursive descent against
  [`../../../spec/grammar.md`](../../../spec/grammar.md). Error
  recovery: parse keeps going past errors to produce diagnostics for
  as much of the file as possible (LSP needs this).
- **CST data types** — `SyntaxKind`, `Token`, `Node`, `Element`. A
  lossless concrete-syntax tree: walking the tree and concatenating
  every token's text reproduces the original source byte-for-byte.
- **AST views** — typed accessors over the CST that downstream
  passes (typeck, codegen) walk. AST views skip trivia and expose
  structured fields (e.g. `FnDecl.name()`, `FnDecl.params()`).
- **Source maps** — every CST token carries an absolute byte offset.
  `(file, line, col)` is computed on demand via the lexer's line-
  break index.
- **Error recovery** — diagnostics emitted with `LEX*` and `PAR*`
  codes per [`../../../spec/diagnostics.md`](../../../spec/diagnostics.md);
  parsing continues past errors.

**Does not own:**

- Name resolution → `typeck/`.
- Type inference → `typeck/`.
- Anything semantic — the parser knows shapes, not meaning.

## Why CST, not AST-only

`q64` is the formatter, the LSP server, and the show / introspection
binary all in one. Three of its four jobs need lossless source:

- `q64 fmt` round-trips source — every whitespace token, every
  comment, every trailing comma must survive the parse-print cycle.
- `q64 lsp` re-parses on every keystroke; an incremental design
  reuses unchanged subtrees, which requires the original tree to
  carry source positions.
- `q64 show` prints introspection output with precise spans.

An AST-first design throws away the trivia the formatter and LSP
need, forcing those tools to re-read the source. The CST keeps
everything; the AST is a typed view *over* the CST for codegen-
shaped consumers.

The pattern follows what every modern language with both a compiler
and a formatter has converged on:

| Language | CST library         | Used by                            |
|----------|---------------------|------------------------------------|
| Swift    | SwiftSyntax         | swift-format, sourcekit-lsp        |
| Rust     | rowan               | rust-analyzer, rustfmt's resyntax  |
| C#       | Roslyn red-green    | dotnet format, the C# compiler     |
| Many     | tree-sitter         | most editors' syntax highlighting  |

## Design

### CST shape (Roslyn-lite, single-tree)

The CST is one tree with two element kinds at every position:

```
Element := Token | Node

Token := { kind: SyntaxKind, text: []const u8, offset: u32 }
Node  := { kind: SyntaxKind, children: []Element }
```

Trivia (whitespace, newlines, line comments, doc comments) is
represented as a token kind — not as a separate field. Trivia tokens
appear as leaves in the tree alongside other tokens. AST views skip
them; the formatter walks them.

The lossless invariant:

```
for every source S:
    serialize(parse(S)) == S
```

Tests in [`../../../spec/tests/`](../../../spec/tests/) include
golden positives that exercise this property end-to-end.

### Future: red-green upgrade

The Roslyn-lite shape above stores every token's text inline. This
is fine for v0 and through any single-file workflow. When
incremental re-parsing for the LSP starts to bite (large files,
many edits per second), upgrade to a rowan-style red-green tree:

- **Green tree** — immutable, hash-consed, parent-less; structural
  sharing across edits.
- **Red tree** — created on demand, wraps a green node with a parent
  pointer and absolute offset.

The CST API stays the same; only the storage backend changes.

### AST views

`ast.zig` defines typed views over CST nodes. Each view is a thin
wrapper around a `*Node` that exposes the spec's structured
accessors:

```zig
pub const FnDecl = struct {
    cst: *const Node,
    pub fn name(self: FnDecl) ?Token { ... }
    pub fn params(self: FnDecl) ?Params { ... }
    pub fn returnType(self: FnDecl) ?TypeExpr { ... }
    pub fn effectSpec(self: FnDecl) ?EffectSpec { ... }
    pub fn whereClause(self: FnDecl) ?WhereClause { ... }
    pub fn body(self: FnDecl) ?Block { ... }
};
```

Views skip trivia, return `?T` for optional spec positions, and
never allocate.

## Inputs / outputs

- **In:** `.q` source bytes from disk, stdin, or LSP buffers.
- **Out:** a CST (lossless), AST views over it, a list of
  diagnostics with `LEX*` and `PAR*` codes (per
  [`../../../spec/diagnostics.md`](../../../spec/diagnostics.md)).

## Files

| File           | Status          | Purpose                                                  |
|----------------|-----------------|----------------------------------------------------------|
| `cst.zig`      | scaffolded      | `SyntaxKind`, `Token`, `Node`, `Element`, `serialize()`. |
| `lex.zig`      | not yet         | Bytes → token stream (trivia preserved).                 |
| `parse.zig`    | not yet         | Tokens → CST tree.                                       |
| `ast.zig`      | not yet         | Typed AST views over the CST.                            |
| `diag.zig`     | not yet         | Diagnostic envelope construction (matches `diagnostics.md`). |

## External

None. Pure Zig.
