import { test, expect } from "bun:test";
import { LspClient } from "../src/harness.ts";

const SERVER = process.env.Q64_LSP_SERVER ?? "../packages/server/dist/node.js";

const SRC =
  "struct Point { x: i64 }\nconst MAX: i64 = 10\nfn add(a: i64) -> i64 { a }\n";

interface DocSymbol {
  name: string;
  kind: number;
  range: { start: { line: number; character: number }; end: { line: number; character: number } };
  selectionRange: { start: { line: number; character: number } };
}

test("documentSymbol lists top-level declarations with kinds", async () => {
  const client = new LspClient(SERVER);
  await client.initialize();
  const uri = "file:///outline.q";
  client.openDocument(uri, SRC);

  const res = await client.documentSymbols(uri);
  const syms = res.result as DocSymbol[];

  // Declaration order.
  expect(syms.map((s) => s.name)).toEqual(["Point", "MAX", "add"]);
  // LSP SymbolKind: Struct = 23, Constant = 14, Function = 12.
  expect(syms.map((s) => s.kind)).toEqual([23, 14, 12]);
  // The selection range points at the name token (`add` on line 2, char 3).
  expect(syms[2].selectionRange.start).toEqual({ line: 2, character: 3 });

  await client.shutdown();
});

test("documentSymbol on an empty document is an empty list", async () => {
  const client = new LspClient(SERVER);
  await client.initialize();
  const uri = "file:///outline-empty.q";
  client.openDocument(uri, "");
  const res = await client.documentSymbols(uri);
  expect(res.result).toEqual([]);
  await client.shutdown();
});
