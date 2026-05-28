/**
 * `q64 show types <expr>` and `q64 show effects <fn>` — introspection
 * (spec/q64-cli.md §"q64 show kinds").
 *
 * Test-first: `show` is not implemented in v0, so these assert the success
 * contract (exit 0, output on stdout) as `test.failing` until it lands.
 */
import { describe, expect, test } from "bun:test";
import { binaryAvailable, fixture, runCli } from "../../src/harness";

describe.skipIf(!binaryAvailable())("q64 show types", () => {
  test.failing("prints the inferred type of an expression, exit 0", () => {
    const r = runCli(["show", "types", "1 + 2", "--qube", fixture("hello.q")]);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim().length).toBeGreaterThan(0);
  });
});

describe.skipIf(!binaryAvailable())("q64 show effects", () => {
  test.failing("prints the effect set of a function, exit 0", () => {
    const r = runCli(["show", "effects", "main", "--qube", fixture("hello.q")]);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim().length).toBeGreaterThan(0);
  });
});
