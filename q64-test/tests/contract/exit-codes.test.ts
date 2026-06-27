/**
 * Exit-code matrix (spec/q64-cli.md §"Exit codes"):
 *   0 success · 1 panic · 2 usage · 64 compile · 65 input · 70 ICE · N env.exit
 * The codes reachable through implemented commands run for real; the rest are
 * `.todo` until the owning subcommand lands.
 */
import { describe, expect, test } from "bun:test";
import { binaryAvailable, fixture, hostAvailable, runCli } from "../../src/harness";

describe.skipIf(!binaryAvailable())("exit codes (implemented paths)", () => {
  test("no subcommand → usage error, exit 2", () => {
    expect(runCli([]).exitCode).toBe(2);
  });

  test("unknown subcommand → usage error, exit 2", () => {
    expect(runCli(["frobnicate"]).exitCode).toBe(2);
  });

  test("clean `check` → exit 0", () => {
    expect(runCli(["check", fixture("hello.q"), "--diagnostics", "json"]).exitCode).toBe(0);
  });

  test("`check` with an error-severity diagnostic → non-zero exit", () => {
    expect(runCli(["check", fixture("parse-error.q"), "--diagnostics", "json"]).exitCode).not.toBe(0);
  });

  test("unreadable input file → non-zero exit", () => {
    expect(runCli(["check", fixture("missing.q"), "--diagnostics", "json"]).exitCode).not.toBe(0);
  });

  test("internal error (ICE) exits 70 with a Q9xxx internal-severity envelope", () => {
    const r = runCli(["--version"], { env: { Q64_FORCE_ICE: "1" } });
    expect(r.exitCode).toBe(70);
    expect(r.envelope?.diagnostics?.[0]?.code).toMatch(/^Q9/);
    expect(r.envelope?.diagnostics?.[0]?.severity).toBe("internal");
  });
});

// `run`-reachable exit codes — now that `q64 run` lands, these run for real
// (gated on the runtime host being built). `build`-based codes stay test-first.
describe.skipIf(!binaryAvailable() || !hostAvailable())("exit codes (run surface)", () => {
  test("input error (file not found) exits 65", () => {
    expect(runCli(["run", fixture("missing.q")]).exitCode).toBe(65);
  });

  test("uncaught program panic exits 1", () => {
    expect(runCli(["run", fixture("panic.q")]).exitCode).toBe(1);
  });

  test("`env.exit(N)` exits with code N", () => {
    expect(runCli(["run", fixture("exit.q")]).exitCode).toBe(3);
  });
});

// Test-first: exit codes not reachable through implemented commands (`build`).
describe.skipIf(!binaryAvailable())("exit codes (spec surface)", () => {
  test.failing("compile error (any error-severity diagnostic) exits 64", () => {
    expect(runCli(["build", fixture("parse-error.q"), "--out", "/tmp/q64-ec.wasm"]).exitCode).toBe(64);
  });
});
