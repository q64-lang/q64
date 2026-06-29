import { test, expect } from "bun:test";
import {
  LspClient,
  type PublishDiagnosticsParams,
} from "../src/harness.ts";

const SERVER = process.env.Q64_LSP_SERVER ?? "../packages/server/dist/node.js";

// A q64 source that the *semantic* passes (not the parser) reject: a `@realtime`
// function that also performs I/O. It parses cleanly; only the effect check
// (EFF120) flags it — so seeing it through the LSP proves sema is wired into the
// wasm core, not just the lexer/parser.
const EFFECT_VIOLATION = 'pub fn render @realtime + @io { env.out("x") }\n';

async function diagnosticsFor(uri: string, text: string) {
  const client = new LspClient(SERVER);
  await client.initialize();
  client.openDocument(uri, text);
  const note = await client.waitForNotification(
    "textDocument/publishDiagnostics",
    (m) => (m.params as PublishDiagnosticsParams).uri === uri,
  );
  await client.shutdown();
  return (note.params as PublishDiagnosticsParams).diagnostics;
}

test("clean source yields no diagnostics", async () => {
  const diags = await diagnosticsFor("file:///clean.q", "fn main() {}\n");
  expect(diags).toHaveLength(0);
});

test("empty document yields no diagnostics (zero-length input path)", async () => {
  // A new/blank buffer hits the bindings' zero-length branch — it must not throw.
  const diags = await diagnosticsFor("file:///empty.q", "");
  expect(diags).toHaveLength(0);
});

test("stray carriage return reports LEX010", async () => {
  const diags = await diagnosticsFor("file:///cr.q", "fn main()\r {}\n");
  expect(diags.length).toBeGreaterThan(0);
  expect(diags[0].code).toBe("LEX010");
  expect(diags[0].severity).toBe(1); // Error
  expect(diags[0].source).toBe("q64");
});

test("semantic diagnostics surface (sema passes wired into the core)", async () => {
  const diags = await diagnosticsFor("file:///eff.q", EFFECT_VIOLATION);
  expect(diags.map((d) => d.code)).toContain("EFF120");
  expect(diags[0].source).toBe("q64");
  expect(diags[0].severity).toBe(1); // Error
});

test("didChange re-validates the buffer", async () => {
  const client = new LspClient(SERVER);
  await client.initialize();
  const uri = "file:///change.q";
  const sameUri = (m: { params: unknown }) =>
    (m.params as PublishDiagnosticsParams).uri === uri;

  client.openDocument(uri, "fn main() {}\n");
  const first = (
    await client.waitForNotification("textDocument/publishDiagnostics", sameUri)
  ).params as PublishDiagnosticsParams;
  expect(first.diagnostics).toHaveLength(0);

  // Register the waiter BEFORE the change so the post-open publish can't satisfy it.
  const after = client.nextNotification(
    "textDocument/publishDiagnostics",
    sameUri,
  );
  client.changeDocument(uri, EFFECT_VIOLATION);
  const changed = (await after).params as PublishDiagnosticsParams;
  expect(changed.diagnostics.map((d) => d.code)).toContain("EFF120");

  await client.shutdown();
});

test("didClose clears diagnostics", async () => {
  const client = new LspClient(SERVER);
  await client.initialize();
  const uri = "file:///close.q";
  const sameUri = (m: { params: unknown }) =>
    (m.params as PublishDiagnosticsParams).uri === uri;

  client.openDocument(uri, "fn main()\r {}\n"); // LEX010 → non-empty
  const opened = (
    await client.waitForNotification("textDocument/publishDiagnostics", sameUri)
  ).params as PublishDiagnosticsParams;
  expect(opened.diagnostics.length).toBeGreaterThan(0);

  const cleared = client.nextNotification(
    "textDocument/publishDiagnostics",
    sameUri,
  );
  client.closeDocument(uri);
  expect(((await cleared).params as PublishDiagnosticsParams).diagnostics).toHaveLength(0);

  await client.shutdown();
});
