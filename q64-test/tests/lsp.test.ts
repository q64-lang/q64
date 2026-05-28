/**
 * `q64 lsp` — language server over stdin/stdout, LSP 3.17 (spec/q64-cli.md §LSP).
 *
 * Test-first: not implemented in v0. Each test drives a real `initialize`
 * handshake (and request) and asserts a JSON-RPC response comes back on stdout;
 * `test.failing` until the server exists.
 */
import { describe, expect, test } from "bun:test";
import { binaryAvailable, lspFrame, lspInitialize, runCli } from "../src/harness";

function lspSession(...messages: string[]) {
  return runCli(["lsp"], { stdin: messages.join("") });
}

describe.skipIf(!binaryAvailable())("q64 lsp", () => {
  test.failing("responds to `initialize` with server capabilities", () => {
    const r = lspSession(lspInitialize());
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("capabilities");
  });

  test.failing("`textDocument/diagnostic` returns a diagnostics result", () => {
    const r = lspSession(
      lspInitialize(),
      lspFrame({ jsonrpc: "2.0", id: 2, method: "textDocument/diagnostic", params: {} }),
    );
    expect(r.stdout).toContain("\"id\":2");
  });

  test.failing("`textDocument/hover` returns hover info for a symbol", () => {
    const r = lspSession(
      lspInitialize(),
      lspFrame({ jsonrpc: "2.0", id: 3, method: "textDocument/hover", params: {} }),
    );
    expect(r.stdout).toContain("\"id\":3");
  });

  test.failing("`textDocument/definition` resolves a definition location", () => {
    const r = lspSession(
      lspInitialize(),
      lspFrame({ jsonrpc: "2.0", id: 4, method: "textDocument/definition", params: {} }),
    );
    expect(r.stdout).toContain("\"id\":4");
  });

  test.failing("`textDocument/formatting` delegates to q64 fmt", () => {
    const r = lspSession(
      lspInitialize(),
      lspFrame({ jsonrpc: "2.0", id: 5, method: "textDocument/formatting", params: {} }),
    );
    expect(r.stdout).toContain("\"id\":5");
  });

  test.failing("`textDocument/codeAction` surfaces repair objects as actions", () => {
    const r = lspSession(
      lspInitialize(),
      lspFrame({ jsonrpc: "2.0", id: 6, method: "textDocument/codeAction", params: {} }),
    );
    expect(r.stdout).toContain("\"id\":6");
  });
});
