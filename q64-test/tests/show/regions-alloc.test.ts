/**
 * `q64 show regions <fn>` and `q64 show alloc <fn>` — region/allocation
 * introspection (spec/q64-cli.md §"q64 show kinds"). Not implemented in v0.
 */
import { describe, test } from "bun:test";

describe("q64 show regions", () => {
  test.todo("lists the regions a function uses or borrows from");
});

describe("q64 show alloc", () => {
  test.todo("prints per-allocation-site region attribution for a function");
});
