/**
 * Exit-code matrix (spec/q64-cli.md §"Exit codes"):
 *   0 success · 1 panic · 2 usage · 64 compile · 65 input · 70 ICE · N env.exit
 * The codes reachable through implemented commands run for real; the rest are
 * `.todo` until the owning subcommand lands.
 */
import { describe, expect, test } from "bun:test";
import { binaryAvailable, fixture, runCli } from "../../src/harness";

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
});

describe("exit codes (spec surface)", () => {
  test.todo("compile error (any error-severity diagnostic) exits 64");
  test.todo("input error (file not found / unreadable) exits 65");
  test.todo("uncaught program panic exits 1");
  test.todo("`env.exit(N)` exits with code N");
  test.todo("internal compiler error (ICE) exits 70 with a Q9xxx diagnostic");
});
