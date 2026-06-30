import { test, expect } from "bun:test";
import { LspClient } from "../src/harness.ts";

const SERVER = process.env.Q64_LSP_SERVER ?? "../packages/server/dist/node.js";

const SRC = "struct Point { x: i64 }\nfn add(a: i64) -> i64 { a }\n";

interface CompletionItem {
  label: string;
  kind: number;
}

async function completionItems(uri: string, line: number, character: number) {
  const client = new LspClient(SERVER);
  await client.initialize();
  client.openDocument(uri, SRC);
  const res = await client.completion(uri, line, character);
  await client.shutdown();
  return res.result as CompletionItem[];
}

test("completion offers in-scope symbols and keywords", async () => {
  const items = await completionItems("file:///complete.q", 1, 24);
  const byLabel = new Map(items.map((i) => [i.label, i.kind]));

  // Top-level symbols, with LSP CompletionItemKind: Function = 3, Struct = 22.
  expect(byLabel.get("add")).toBe(3);
  expect(byLabel.get("Point")).toBe(22);
  // Keywords (Keyword = 14) come from the lexer's authoritative table.
  expect(byLabel.get("fn")).toBe(14);
  expect(byLabel.get("match")).toBe(14);
});

test("completion inside a function offers its params and bindings", async () => {
  const client = new LspClient(SERVER);
  await client.initialize();
  const uri = "file:///complete-locals.q";
  // `a`/`b` are params; `sum` is a let binding. Cursor on line 2 (`sum`), in body.
  client.openDocument(uri, "fn calc(a: i64, b: i64) -> i64 {\n  let sum = a\n  sum\n}\n");
  const res = await client.completion(uri, 2, 3);
  const items = res.result as CompletionItem[];
  const byLabel = new Map(items.map((i) => [i.label, i.kind]));

  // Locals are CompletionItemKind.Variable = 6.
  expect(byLabel.get("a")).toBe(6);
  expect(byLabel.get("b")).toBe(6);
  expect(byLabel.get("sum")).toBe(6);
  // The enclosing function and keywords are still offered.
  expect(byLabel.get("calc")).toBe(3);
  expect(byLabel.get("fn")).toBe(14);
  await client.shutdown();
});

test("completion on an empty document still offers keywords", async () => {
  const client = new LspClient(SERVER);
  await client.initialize();
  const uri = "file:///complete-empty.q";
  client.openDocument(uri, "");
  const res = await client.completion(uri, 0, 0);
  const items = res.result as CompletionItem[];
  expect(items.length).toBeGreaterThan(0);
  expect(items.every((i) => i.kind === 14)).toBe(true); // all keywords
  await client.shutdown();
});
