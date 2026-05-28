/**
 * `q64 show regions <fn>` and `q64 show alloc <fn>` — region/allocation
 * introspection (spec/q64-cli.md §"q64 show kinds").
 *
 * Test-first: not implemented in v0; `test.failing` until it lands.
 */
import { describe, expect, test } from "bun:test";
import { binaryAvailable, fixture, runCli } from "../../src/harness";

describe.skipIf(!binaryAvailable())("q64 show regions", () => {
  test.failing("lists the regions a function uses or borrows from, exit 0", () => {
    const r = runCli(["show", "regions", "main", "--qube", fixture("hello.q")]);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim().length).toBeGreaterThan(0);
  });
});

describe.skipIf(!binaryAvailable())("q64 show alloc", () => {
  test.failing("prints per-allocation-site region attribution, exit 0", () => {
    const r = runCli(["show", "alloc", "main", "--qube", fixture("hello.q")]);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim().length).toBeGreaterThan(0);
  });
});
