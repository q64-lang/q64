/**
 * `q64 show modules [--prelude]` and `q64 show graph <stage>` — module tree
 * and stream-graph introspection (spec/q64-cli.md §"q64 show kinds").
 * Not implemented in v0.
 */
import { describe, test } from "bun:test";

describe("q64 show modules", () => {
  test.todo("prints the module tree: each file's path, header doc, exported names");
  test.todo("`--prelude` lists the auto-prelude reachable names");
});

describe("q64 show graph", () => {
  test.todo("prints the stream-graph topology rooted at a stage");
});
