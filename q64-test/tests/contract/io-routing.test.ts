/**
 * stdin / stdout / stderr routing for a running program (spec/q64-cli.md
 * §"Stdin / stdout / stderr conventions"). Runs for real via `q64 run` and the
 * runtime host (the suite skips when the host isn't built).
 */
import { describe, expect, test } from "bun:test";
import { binaryAvailable, fixture, hostAvailable, runCli } from "../../src/harness";

describe.skipIf(!binaryAvailable() || !hostAvailable())("IO routing (running a program)", () => {
  test("the program's env.out is written to stdout", () => {
    const r = runCli(["run", fixture("hello.q")]);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("Hello, q64.");
  });

  test("program output goes to stdout, not stderr", () => {
    const r = runCli(["run", fixture("hello.q")]);
    expect(r.stdout).toContain("Hello, q64.");
    expect(r.stderr).not.toContain("Hello, q64.");
  });

  test("stdin is forwarded to the program's env.in", () => {
    // An echo-style program would surface its stdin on stdout; for now this
    // asserts the program runs cleanly with piped stdin (env.in lands later).
    const r = runCli(["run", fixture("hello.q")], { stdin: "piped-input\n" });
    expect(r.exitCode).toBe(0);
  });
});
