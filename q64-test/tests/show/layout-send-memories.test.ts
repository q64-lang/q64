/**
 * `q64 show layout <type>`, `q64 show send <type>`, `q64 show memories` —
 * memory-shape introspection (spec/q64-cli.md §"q64 show kinds").
 * Not implemented in v0.
 */
import { describe, test } from "bun:test";

describe("q64 show layout", () => {
  test.todo("prints the memory layout of a type");
});

describe("q64 show send", () => {
  test.todo("explains @send-derivation for a type");
});

describe("q64 show memories", () => {
  test.todo("lists the wasm memory declarations the program produces");
});
