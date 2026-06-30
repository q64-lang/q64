import { test, expect } from "bun:test";
import { LspClient } from "../src/harness.ts";

const SERVER = process.env.Q64_LSP_SERVER ?? "../packages/server/dist/node.js";

// `greet` is declared on line 0 (its name starts at character 3) and used on
// line 1 (`fn main() { greet() }` — the call's `greet` starts at character 12).
const SRC = "fn greet() {}\nfn main() { greet() }\n";

async function open(uri: string) {
  const client = new LspClient(SERVER);
  await client.initialize();
  client.openDocument(uri, SRC);
  return client;
}

test("hover over a use shows the function signature", async () => {
  const client = await open("file:///hover.q");
  const res = await client.hover("file:///hover.q", 1, 13);
  const hover = res.result as { contents: { kind: string; value: string } } | null;
  // `greet` takes no params and declares no return type.
  expect(hover?.contents.value).toBe("fn greet()");
  await client.shutdown();
});

test("hover renders the full signature (params + return + pub)", async () => {
  const uri = "file:///sig.q";
  const src = "pub fn add(a: i64, b: i64) -> i64 { a }\n";
  const client = await openSrc(uri, src);
  // hover over the declaration name `add` (char 7).
  const res = await client.hover(uri, 0, 7);
  const hover = res.result as { contents: { value: string } } | null;
  expect(hover?.contents.value).toBe("pub fn add(a: i64, b: i64) -> i64");
  await client.shutdown();
});

test("hover over a keyword returns null", async () => {
  const client = await open("file:///hover-kw.q");
  // line 1, character 0 is the `fn` keyword — not an identifier.
  const res = await client.hover("file:///hover-kw.q", 1, 0);
  expect(res.result).toBeNull();
  await client.shutdown();
});

test("definition jumps from a use to the declaration", async () => {
  const uri = "file:///def.q";
  const client = await open(uri);
  const res = await client.definition(uri, 1, 13);
  const loc = res.result as {
    uri: string;
    range: { start: { line: number; character: number }; end: { line: number; character: number } };
  } | null;
  expect(loc?.uri).toBe(uri);
  // The declaration `greet` is on line 0, characters 3..8.
  expect(loc?.range.start).toEqual({ line: 0, character: 3 });
  expect(loc?.range.end).toEqual({ line: 0, character: 8 });
  await client.shutdown();
});

test("definition on a non-identifier returns null", async () => {
  const uri = "file:///def-none.q";
  const client = await open(uri);
  const res = await client.definition(uri, 0, 2); // the space before `greet`
  expect(res.result).toBeNull();
  await client.shutdown();
});

// Locals: scope-aware hover + definition for params and `let` bindings.

async function openSrc(uri: string, src: string) {
  const client = new LspClient(SERVER);
  await client.initialize();
  client.openDocument(uri, src);
  return client;
}

test("hover + definition resolve a parameter use to its binding", async () => {
  // `a` is the parameter (char 7) and is used in the body (char 32).
  const uri = "file:///param.q";
  const src = "fn add(a: i64, b: i64) -> i64 { a }\n";
  const client = await openSrc(uri, src);

  const hov = await client.hover(uri, 0, 32);
  expect((hov.result as { contents: { value: string } } | null)?.contents.value).toBe("local a");

  const def = await client.definition(uri, 0, 32);
  const loc = def.result as { range: { start: { line: number; character: number }; end: { line: number; character: number } } } | null;
  expect(loc?.range.start).toEqual({ line: 0, character: 7 });
  expect(loc?.range.end).toEqual({ line: 0, character: 8 });
  await client.shutdown();
});

test("hover + definition resolve a let-binding use to its declaration", async () => {
  // `count` is declared on line 1 (char 6) and used on line 2 (char 10).
  const uri = "file:///let.q";
  const src = "fn main() {\n  let count = 1\n  env.out(count)\n}\n";
  const client = await openSrc(uri, src);

  const hov = await client.hover(uri, 2, 12);
  expect((hov.result as { contents: { value: string } } | null)?.contents.value).toBe("local count");

  const def = await client.definition(uri, 2, 12);
  const loc = def.result as { range: { start: { line: number; character: number }; end: { line: number; character: number } } } | null;
  expect(loc?.range.start).toEqual({ line: 1, character: 6 });
  expect(loc?.range.end).toEqual({ line: 1, character: 11 });
  await client.shutdown();
});
