/**
 * `q64 run <file>` and implicit run (`q64 <file.q>`) — compile to wasm and run
 * via the runtime host (spec/q64-cli.md §Synopsis, §Subcommands, §"Exit codes").
 *
 * `run` compiles to a raw core (the `env.*` host faces) and executes it on
 * `q64-wasmtime-host`, which preserves the full `env.exit(N)` code. The suite
 * skips when either the q64 binary or the host is unavailable; `zig build
 * cli-tests` builds both and points Q64_WASMTIME_HOST at the host.
 */
import { describe, expect, test } from "bun:test";
import { binaryAvailable, fixture, hostAvailable, runCli } from "../src/harness";

describe.skipIf(!binaryAvailable() || !hostAvailable())("q64 run", () => {
  test("`q64 run hello.q` runs the program and writes its output to stdout", () => {
    const r = runCli(["run", fixture("hello.q")]);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("Hello, q64.");
  });

  test("`q64 hello.q` (implicit run) dispatches to `run`", () => {
    const r = runCli([fixture("hello.q")]);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("Hello, q64.");
  });

  test("a clean program exits 0", () => {
    expect(runCli(["run", fixture("hello.q")]).exitCode).toBe(0);
  });

  test("an uncaught `panic` exits 1 (per §Exit codes)", () => {
    expect(runCli(["run", fixture("panic.q")]).exitCode).toBe(1);
  });

  test("`env.exit(N)` propagates exit code N", () => {
    expect(runCli(["run", fixture("exit.q")]).exitCode).toBe(3);
  });
});
