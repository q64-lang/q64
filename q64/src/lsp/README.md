# q64/src/lsp

The `q64 lsp` language server.

> **Status: not yet implemented.**

## Scope

**Owns:**
- LSP 3.17 server over stdin/stdout.
- Incremental document state — keep parsed/checked snapshots per open
  buffer, invalidate on edits.
- Mapping the [diagnostic envelope](../../../spec/diagnostics.md) to LSP
  `Diagnostic[]` (severity, code, range, related-information from
  `labels`).
- Mapping `repair` objects to LSP `CodeAction` entries.

**Does not own:**
- Parsing, typechecking, region/effect analysis — calls into sibling
  folders.
- Formatting — delegates to `fmt/`.
- Introspection — delegates to `show/`.

## Inputs / outputs

- **In:** LSP wire messages on stdin (initialize, didOpen, didChange,
  diagnostic, hover, definition, formatting, codeAction).
- **Out:** LSP responses on stdout; tracing notifications on stderr.

## Supported requests (v0)

Per [`spec/q64-cli.md`](../../../spec/q64-cli.md) §LSP:
`textDocument/diagnostic`, `textDocument/hover`,
`textDocument/definition`, `textDocument/formatting`,
`textDocument/codeAction`.

Eventual: completion, references, rename, semantic tokens, inlay hints.

## External

LSP 3.17 specification — https://microsoft.github.io/language-server-protocol/
