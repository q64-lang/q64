import { test, expect } from "bun:test";
import {
  LspClient,
  type PublishDiagnosticsParams,
} from "../src/harness.ts";

const SERVER = process.env.Q64_LSP_SERVER ?? "../packages/server/dist/node.js";

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

test("stray carriage return reports LEX010", async () => {
  const diags = await diagnosticsFor("file:///cr.q", "fn main()\r {}\n");
  expect(diags.length).toBeGreaterThan(0);
  expect(diags[0].code).toBe("LEX010");
  expect(diags[0].severity).toBe(1); // Error
  expect(diags[0].source).toBe("q64");
});
