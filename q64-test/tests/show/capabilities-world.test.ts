/**
 * `q64 show capabilities <qube>`, `q64 show denials <fn>`, `q64 show world
 * <qube>` — the component-model / capability surface (spec/q64-cli.md
 * §"q64 show kinds").
 *
 * Test-first: not implemented in v0; `test.failing` until it lands.
 */
import { describe, expect, test } from "bun:test";
import { binaryAvailable, fixture, runCli } from "../../src/harness";

describe.skipIf(!binaryAvailable())("q64 show capabilities", () => {
  test.failing("prints the compiler-derived capability set for a qube, exit 0", () => {
    const r = runCli(["show", "capabilities", "--qube", fixture("hello.q")]);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim().length).toBeGreaterThan(0);
  });
});

describe.skipIf(!binaryAvailable())("q64 show denials", () => {
  test.failing("prints reachability into with_capabilities(deny: …) blocks, exit 0", () => {
    const r = runCli(["show", "denials", "main", "--qube", fixture("hello.q")]);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim().length).toBeGreaterThan(0);
  });
});

describe.skipIf(!binaryAvailable())("q64 show world", () => {
  test.failing("prints the synthesized WIT world (exports + imports), exit 0", () => {
    const r = runCli(["show", "world", "--qube", fixture("hello.q")]);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim().length).toBeGreaterThan(0);
  });
});
