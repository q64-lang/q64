import { test, expect } from "bun:test";
import { LspClient } from "../src/harness.ts";

const SERVER = process.env.Q64_LSP_SERVER ?? "../packages/server/dist/node.js";

test("initialize advertises full text sync and diagnostics", async () => {
  const client = new LspClient(SERVER);
  const res = await client.initialize();
  const caps = (res.result as { capabilities: Record<string, unknown> })
    .capabilities;
  // textDocumentSync === 1 (Full)
  expect(caps.textDocumentSync).toBe(1);
  expect(caps.hoverProvider).toBe(true);
  expect(caps.definitionProvider).toBe(true);
  expect(caps.documentSymbolProvider).toBe(true);
  expect((caps.completionProvider as { resolveProvider: boolean }).resolveProvider).toBe(false);
  await client.shutdown();
});
