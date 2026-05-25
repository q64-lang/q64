/**
 * `q64 run <file>` and implicit run (`q64 <file.q>`) — compile to wasm in
 * memory and run (spec/q64-cli.md §Synopsis, §Subcommands, §"Exit codes").
 *
 * Test-first: these assert the spec'd behavior now. `run` is not implemented in
 * v0 (the binary exposes `emit`/`check`), so they are `test.failing` — red
 * today, and they flip the suite red the moment `run` starts honouring the
 * contract, which is the signal to drop `.failing`.
 */
import { describe, expect, test } from "bun:test";
import { binaryAvailable, fixture, runCli } from "../src/harness";

describe.skipIf(!binaryAvailable())("q64 run", () => {
  test.failing("`q64 run hello.q` runs the program and writes its output to stdout", () => {
    const r = runCli(["run", fixture("hello.q")]);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("Hello, q64.");
  });

  test.failing("`q64 hello.q` (implicit run) dispatches to `run`", () => {
    const r = runCli([fixture("hello.q")]);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("Hello, q64.");
  });

  test.failing("a clean program exits 0", () => {
    expect(runCli(["run", fixture("hello.q")]).exitCode).toBe(0);
  });

  test.failing("an uncaught `panic` exits 1 (per §Exit codes)", () => {
    expect(runCli(["run", fixture("panic.q")]).exitCode).toBe(1);
  });

  test.failing("`env.exit(N)` propagates exit code N", () => {
    expect(runCli(["run", fixture("exit.q")]).exitCode).toBe(3);
  });
});
