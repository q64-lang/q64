/**
 * Global options (spec/q64-cli.md §"Global options"). `--version` is
 * implemented and runs for real; the remaining flags are `.todo`.
 */
import { describe, expect, test } from "bun:test";
import { binaryAvailable, runCli } from "../../src/harness";

describe.skipIf(!binaryAvailable())("global flags (implemented)", () => {
  test("--version prints a version line on stdout and exits 0", () => {
    const r = runCli(["--version"]);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toMatch(/q64\s+\d+\.\d+\.\d+/);
  });
});

describe("global flags (spec surface)", () => {
  test.todo("--help prints help on stdout and exits 0");
  test.todo("--module name=path maps a module name to a source directory (repeatable)");
  test.todo("--features a,b gates @feature-annotated items (union of all flags)");
  test.todo("--quiet suppresses non-error output");
  test.todo("--verbose adds logging on stderr");
  test.todo("--no-color disables ANSI color in text diagnostics");
});
