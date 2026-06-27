/**
 * Global options (spec/q64-cli.md §"Global options"). `--version` is
 * implemented and runs for real; the rest are test-first (`test.failing`)
 * until the owning command/flag lands.
 */
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, test } from "bun:test";
import { binaryAvailable, fixture, hostAvailable, runCli } from "../../src/harness";

describe.skipIf(!binaryAvailable())("global flags (implemented)", () => {
  test("--version prints a version line on stdout and exits 0", () => {
    const r = runCli(["--version"]);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toMatch(/q64\s+\d+\.\d+\.\d+/);
  });
});

describe.skipIf(!binaryAvailable())("global flags (spec surface)", () => {
  test.failing("--help prints help on stdout and exits 0", () => {
    const r = runCli(["--help"]);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.length).toBeGreaterThan(0);
  });

  test.failing("--module name=path links a dependency during build", () => {
    const out = join(tmpdir(), "q64-mod.wasm");
    const r = runCli(["build", fixture("hello.q"), "--out", out, "--module", "dev.q64.x=/tmp/x"]);
    expect(r.exitCode).toBe(0);
    expect(existsSync(out)).toBe(true);
  });

  test.failing("--features gates @feature-annotated items during build", () => {
    const out = join(tmpdir(), "q64-feat.wasm");
    expect(runCli(["build", fixture("hello.q"), "--out", out, "--features", "fft,mp3"]).exitCode).toBe(0);
  });

  test.failing("--no-color disables ANSI color in text diagnostics", () => {
    const r = runCli(["check", fixture("parse-error.q"), "--no-color"]);
    expect(r.stderr).toMatch(/error\[NAM003\]:/);
  });
});

describe.skipIf(!binaryAvailable() || !hostAvailable())("global flags (run surface)", () => {
  test("--quiet is accepted on a successful run (exit 0)", () => {
    // v0 tolerates the flag; output suppression lands with the flag surface.
    const r = runCli(["run", fixture("hello.q"), "--quiet"]);
    expect(r.exitCode).toBe(0);
  });
});
