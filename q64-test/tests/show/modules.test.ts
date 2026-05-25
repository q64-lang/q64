/**
 * `q64 show modules [--prelude]` and `q64 show graph <stage>` — module tree
 * and stream-graph introspection (spec/q64-cli.md §"q64 show kinds").
 *
 * Test-first: not implemented in v0; `test.failing` until it lands.
 */
import { describe, expect, test } from "bun:test";
import { binaryAvailable, fixture, runCli } from "../../src/harness";

describe.skipIf(!binaryAvailable())("q64 show modules", () => {
  test.failing("prints the module tree (paths, header docs, exported names), exit 0", () => {
    const r = runCli(["show", "modules", "--qube", fixture("hello.q")]);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim().length).toBeGreaterThan(0);
  });

  test.failing("`--prelude` lists the auto-prelude reachable names, exit 0", () => {
    const r = runCli(["show", "modules", "--prelude", "--qube", fixture("hello.q")]);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim().length).toBeGreaterThan(0);
  });
});

describe.skipIf(!binaryAvailable())("q64 show graph", () => {
  test.failing("prints the stream-graph topology rooted at a stage, exit 0", () => {
    const r = runCli(["show", "graph", "main", "--qube", fixture("hello.q")]);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim().length).toBeGreaterThan(0);
  });
});
