/**
 * stdin / stdout / stderr routing for a running program (spec/q64-cli.md
 * §"Stdin / stdout / stderr conventions").
 *
 * Test-first: needs `q64 run`, not implemented in v0, so these assert the
 * routing contract as `test.failing` until run lands.
 */
import { describe, expect, test } from "bun:test";
import { binaryAvailable, fixture, runCli } from "../../src/harness";

describe.skipIf(!binaryAvailable())("IO routing (running a program)", () => {
  test.failing("the program's env.out is written to stdout", () => {
    const r = runCli(["run", fixture("hello.q")]);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("Hello, q64.");
  });

  test.failing("program output goes to stdout, not stderr", () => {
    const r = runCli(["run", fixture("hello.q")]);
    expect(r.stdout).toContain("Hello, q64.");
    expect(r.stderr).not.toContain("Hello, q64.");
  });

  test.failing("stdin is forwarded to the program's env.in", () => {
    // An echo-style program would surface its stdin on stdout; until `run`
    // exists this only asserts the program ran cleanly with piped stdin.
    const r = runCli(["run", fixture("hello.q")], { stdin: "piped-input\n" });
    expect(r.exitCode).toBe(0);
  });
});
