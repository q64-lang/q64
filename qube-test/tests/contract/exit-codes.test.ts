/**
 * qube exit-code matrix (spec/qube-cli.md §"Exit codes"):
 *   0 success · 1 runtime · 2 usage · 64 compile · 65 input · 66 dependency
 *   · 67 registry · 70 internal.
 * Codes reachable on the binary alone run for real; the rest are `.todo`.
 */
import { describe, expect, test } from "bun:test";
import { appManifest, binaryAvailable, makeProject, runCli } from "../../src/harness";

describe.skipIf(!binaryAvailable())("exit codes (implemented paths)", () => {
  test("no subcommand → usage, exit 2", () => {
    expect(runCli([]).exitCode).toBe(2);
  });

  test("unknown subcommand → usage, exit 2", () => {
    expect(runCli(["frobnicate"]).exitCode).toBe(2);
  });

  test("not-yet-implemented subcommand → usage, exit 2", () => {
    expect(runCli(["remove"]).exitCode).toBe(2);
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

  test("internal error (ICE) exits 70 with a Q9xxx internal-severity envelope", () => {
    const r = runCli(["--version"], { env: { QUBE_FORCE_ICE: "1" } });
    expect(r.exitCode).toBe(70);
    expect(r.envelope?.diagnostics?.[0]?.code).toMatch(/^Q9/);
    expect(r.envelope?.diagnostics?.[0]?.severity).toBe("internal");
  });

  test("a registry/auth failure during publish exits 67", () => {
    const proj = makeProject({
      "qube.json5": '{ "name": "dev.q64.pub", "version": "0.1.0", "license": "MIT", "type": "library" }',
      "src/lib.q": "pub fn v() -> i64 { 1 }\n",
    });
    expect(runCli(["publish"], { cwd: proj, timeout: 15_000 }).exitCode).toBe(67);
  });
});

// Test-first: success/compile/dependency/registry codes need the full
// toolchain or registry. `test.failing` until those paths land.
describe.skipIf(!binaryAvailable())("exit codes (spec surface)", () => {
  test.failing("a clean `build` exits 0", () => {
    const proj = makeProject({ "qube.json5": appManifest(), "src/main.q": "fn main { env.out(\"x\") }\n" });
    expect(runCli(["build"], { cwd: proj }).exitCode).toBe(0);
  });

  test.failing("a compile error from q64 exits 64", () => {
    const proj = makeProject({
      "qube.json5": appManifest(),
      "src/main.q": "import q64.math.*\nfn main { env.out(\"x\") }\n",
    });
    expect(runCli(["build"], { cwd: proj }).exitCode).toBe(64);
  });

  test("a dependency cache miss with --offline exits 66", () => {
    const proj = makeProject({
      "qube.json5": '{ "name": "dev.q64.x", "version": "0.1.0", "license": "MIT", "type": "application", "entry": "src/main.q", "dependencies": { "dev.q64.absent": "^9.9" } }',
      "src/main.q": "fn main { env.out(\"x\") }\n",
    });
    // Dependency resolution fails before any compile work, so this needs no
    // q64 — a real exit now that `build` resolves the manifest's deps.
    expect(runCli(["build", "--offline"], { cwd: proj, timeout: 15_000 }).exitCode).toBe(66);
  });
});
