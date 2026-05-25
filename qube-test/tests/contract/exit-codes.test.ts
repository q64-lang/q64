/**
 * qube exit-code matrix (spec/qube-cli.md §"Exit codes"):
 *   0 success · 1 runtime · 2 usage · 64 compile · 65 input · 66 dependency
 *   · 67 registry · 70 internal.
 * Codes reachable on the binary alone run for real; the rest are `.todo`.
 */
import { describe, expect, test } from "bun:test";
import { binaryAvailable, makeProject, runCli } from "../../src/harness";

describe.skipIf(!binaryAvailable())("exit codes (implemented paths)", () => {
  test("no subcommand → usage, exit 2", () => {
    expect(runCli([]).exitCode).toBe(2);
  });

  test("unknown subcommand → usage, exit 2", () => {
    expect(runCli(["frobnicate"]).exitCode).toBe(2);
  });

  test("not-yet-implemented subcommand → usage, exit 2", () => {
    expect(runCli(["build"]).exitCode).toBe(2);
  });

  test("`run` with no manifest → input error, exit 65", () => {
    const empty = makeProject({ ".keep": "" });
    expect(runCli(["run"], { cwd: empty }).exitCode).toBe(65);
  });

  test("`run` on a library qube → usage, exit 2", () => {
    const proj = makeProject({
      "qube.json5": '{ "name": "dev.q64.lib", "version": "0.1.0", "license": "MIT", "type": "library" }',
    });
    expect(runCli(["run"], { cwd: proj }).exitCode).toBe(2);
  });
});

describe("exit codes (spec surface)", () => {
  test.todo("a clean `run` / `build` exits 0");
  test.todo("a runtime failure during run/test exits 1");
  test.todo("a compile error from q64 exits 64");
  test.todo("a dependency resolution failure (or --offline cache miss) exits 66");
  test.todo("a registry/network/auth failure exits 67");
  test.todo("an internal error or ICE propagated from q64 exits 70");
});
