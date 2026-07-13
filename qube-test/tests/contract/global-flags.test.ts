/**
 * Global options (spec/qube-cli.md §"Global options"). `--version`/`-v` and
 * `--help`/`-h` are implemented and run for real; the rest are test-first
 * (`test.failing`) until the owning command/flag lands.
 */
import { describe, expect, test } from "bun:test";
import { Q64_BIN, appManifest, binaryAvailable, makeProject, q64Available, runCli } from "../../src/harness";

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
  // Implemented: --manifest skips upward discovery (the cwd here is NOT the
  // project, so a discovery-based build could not find this manifest).
  test.skipIf(!q64Available())("--manifest <path> builds the pointed-at qube", () => {
    const proj = appProject();
    expect(runCli(["build", "--manifest", `${proj}/qube.json5`, "--addr", "wasm64"], { env: { Q64_BIN } }).exitCode).toBe(0);
  });

  // Implemented as an accepted no-op: build/run dependency resolution is
  // already lock+cache-only, so --offline is unconditionally honoured.
  test.skipIf(!q64Available())("--offline is accepted on a build with no uncached deps", () => {
    expect(runCli(["build", "--offline", "--addr", "wasm64"], { cwd: appProject(), env: { Q64_BIN } }).exitCode).toBe(0);
  });

  test.failing("--frozen is accepted when the lockfile would not change", () => {
    expect(runCli(["build", "--frozen", "--addr", "wasm64"], { cwd: appProject() }).exitCode).toBe(0);
  });

  test.failing("--locked is accepted on a consistent lockfile", () => {
    expect(runCli(["build", "--locked", "--addr", "wasm64"], { cwd: appProject() }).exitCode).toBe(0);
  });

  test.failing("-jN sets build parallelism", () => {
    expect(runCli(["build", "-j2", "--addr", "wasm64"], { cwd: appProject() }).exitCode).toBe(0);
  });

  test.failing("--registry <url> overrides the default registry on a build", () => {
    expect(runCli(["build", "--registry", "https://example.test", "--addr", "wasm64"], { cwd: appProject() }).exitCode).toBe(0);
  });

  test.failing("--diagnostics json renders qube's own diagnostics as envelopes", () => {
    const proj = makeProject({
      "qube.json5": '{ "name": "singlename", "version": "0.1.0", "license": "MIT", "type": "application", "entry": "src/main.q" }',
      "src/main.q": "fn main { env.out(\"x\") }\n",
    });
    const r = runCli(["build", "--diagnostics", "json", "--addr", "wasm64"], { cwd: proj });
    expect((r.envelope?.diagnostics ?? []).some((d) => d.code.startsWith("PKG"))).toBe(true);
  });

  test.failing("--no-color is accepted on a build", () => {
    expect(runCli(["build", "--no-color", "--addr", "wasm64"], { cwd: appProject() }).exitCode).toBe(0);
  });

  test.failing("--quiet suppresses non-error output on a clean build", () => {
    const r = runCli(["build", "--quiet", "--addr", "wasm64"], { cwd: appProject() });
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toBe("");
  });

  test.failing("--verbose adds logging on stderr during a build", () => {
    const r = runCli(["build", "--verbose", "--addr", "wasm64"], { cwd: appProject() });
    expect(r.exitCode).toBe(0);
    expect(r.stderr.length).toBeGreaterThan(0);
  });
});
