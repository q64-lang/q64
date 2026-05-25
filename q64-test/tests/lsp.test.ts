/**
 * `q64 lsp` — language server over stdin/stdout, LSP 3.17
 * (spec/q64-cli.md §LSP). Not implemented in v0.
 */
import { describe, test } from "bun:test";

describe("q64 lsp", () => {
  test.todo("responds to an `initialize` request with server capabilities");
  test.todo("`textDocument/diagnostic` maps the diagnostic envelope to LSP Diagnostic[]");
  test.todo("`textDocument/formatting` delegates to `q64 fmt`");
  test.todo("logging and progress notifications go to stderr, not the wire on stdout");
});
