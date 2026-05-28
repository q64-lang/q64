/**
 * `q64 show layout <type>`, `q64 show send <type>`, `q64 show memories` —
 * memory-shape introspection (spec/q64-cli.md §"q64 show kinds").
 *
 * Test-first: not implemented in v0; `test.failing` until it lands.
 */
import { describe, expect, test } from "bun:test";
import { binaryAvailable, fixture, runCli } from "../../src/harness";

describe.skipIf(!binaryAvailable())("q64 show layout", () => {
  test.failing("prints the memory layout of a type, exit 0", () => {
    const r = runCli(["show", "layout", "i64", "--qube", fixture("hello.q")]);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim().length).toBeGreaterThan(0);
  });
});

describe.skipIf(!binaryAvailable())("q64 show send", () => {
  test.failing("explains @send-derivation for a type, exit 0", () => {
    const r = runCli(["show", "send", "i64", "--qube", fixture("hello.q")]);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim().length).toBeGreaterThan(0);
  });
});

describe.skipIf(!binaryAvailable())("q64 show memories", () => {
  test.failing("lists the wasm memory declarations the program produces, exit 0", () => {
    const r = runCli(["show", "memories", "--qube", fixture("hello.q")]);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim().length).toBeGreaterThan(0);
  });
});
