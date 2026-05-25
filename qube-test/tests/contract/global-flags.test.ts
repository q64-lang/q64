/**
 * Global options (spec/qube-cli.md §"Global options"). `--version`/`-v` and
 * `--help`/`-h` are implemented and run for real; the rest are test-first
 * (`test.failing`) until the owning command/flag lands.
 */
import { describe, expect, test } from "bun:test";
import { appManifest, binaryAvailable, makeProject, runCli } from "../../src/harness";

function appProject() {
  return makeProject({ "qube.json5": appManifest(), "src/main.q": "fn main { env.out(\"x\") }\n" });
}

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

// Test-first: these flags are not honoured by an implemented command yet, so
// each is asserted against a clean build that should accept it. `test.failing`
// until builds (and flag parsing) land.
describe.skipIf(!binaryAvailable())("global flags (spec surface)", () => {
  test.failing("--manifest <path> builds the pointed-at qube", () => {
    const proj = appProject();
    expect(runCli(["build", "--manifest", `${proj}/qube.json5`]).exitCode).toBe(0);
  });

  test.failing("--offline is accepted on a build with no uncached deps", () => {
    expect(runCli(["build", "--offline"], { cwd: appProject() }).exitCode).toBe(0);
  });

  test.failing("--frozen is accepted when the lockfile would not change", () => {
    expect(runCli(["build", "--frozen"], { cwd: appProject() }).exitCode).toBe(0);
  });

  test.failing("--locked is accepted on a consistent lockfile", () => {
    expect(runCli(["build", "--locked"], { cwd: appProject() }).exitCode).toBe(0);
  });

  test.failing("-jN sets build parallelism", () => {
    expect(runCli(["build", "-j2"], { cwd: appProject() }).exitCode).toBe(0);
  });

  test.failing("--registry <url> overrides the default registry on a build", () => {
    expect(runCli(["build", "--registry", "https://example.test"], { cwd: appProject() }).exitCode).toBe(0);
  });

  test.failing("--diagnostics json renders qube's own diagnostics as envelopes", () => {
    const proj = makeProject({
      "qube.json5": '{ "name": "singlename", "version": "0.1.0", "license": "MIT", "type": "application", "entry": "src/main.q" }',
      "src/main.q": "fn main { env.out(\"x\") }\n",
    });
    const r = runCli(["build", "--diagnostics", "json"], { cwd: proj });
    expect((r.envelope?.diagnostics ?? []).some((d) => d.code.startsWith("PKG"))).toBe(true);
  });

  test.failing("--no-color is accepted on a build", () => {
    expect(runCli(["build", "--no-color"], { cwd: appProject() }).exitCode).toBe(0);
  });

  test.failing("--quiet suppresses non-error output on a clean build", () => {
    const r = runCli(["build", "--quiet"], { cwd: appProject() });
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toBe("");
  });

  test.failing("--verbose adds logging on stderr during a build", () => {
    const r = runCli(["build", "--verbose"], { cwd: appProject() });
    expect(r.exitCode).toBe(0);
    expect(r.stderr.length).toBeGreaterThan(0);
  });
});
