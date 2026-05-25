/**
 * Global options (spec/qube-cli.md §"Global options"). `--version`/`-v` and
 * `--help`/`-h` are implemented and run for real; the rest are `.todo`.
 */
import { describe, expect, test } from "bun:test";
import { binaryAvailable, runCli } from "../../src/harness";

describe.skipIf(!binaryAvailable())("global flags (implemented)", () => {
  test("--version prints a version line on stdout and exits 0", () => {
    const r = runCli(["--version"]);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toMatch(/qube\s+\d+\.\d+\.\d+/);
  });

  test("-v is an alias for --version", () => {
    expect(runCli(["-v"]).stdout).toMatch(/qube\s+\d+\.\d+\.\d+/);
  });

  test("--help exits 0", () => {
    expect(runCli(["--help"]).exitCode).toBe(0);
  });

  test("-h is an alias for --help", () => {
    expect(runCli(["-h"]).exitCode).toBe(0);
  });
});

describe("global flags (spec surface)", () => {
  test.todo("--manifest <path> overrides manifest discovery");
  test.todo("--offline refuses network access and fails on a cache miss");
  test.todo("--frozen refuses to update the lockfile");
  test.todo("--locked allows lockfile-consistent network fetches");
  test.todo("-jN sets build parallelism");
  test.todo("--registry <url> overrides the default registry");
});
