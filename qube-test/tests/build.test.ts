/**
 * `qube build [--target <name>]` (spec/qube-cli.md §Subcommands, §"target/
 * layout"). Compiles the qube to wasm, invoking q64 per source file.
 *
 * Test-first: not implemented in v0 (stub exits 2 — pinned in usage.test.ts).
 * `test.failing` asserts the artifacts/exit codes until it lands.
 */
import { existsSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, test } from "bun:test";
import { appManifest, binaryAvailable, makeProject, runCli } from "../src/harness";

function appProject() {
  return makeProject({ "qube.json5": appManifest(), "src/main.q": "fn main { env.out(\"x\") }\n" });
}

describe.skipIf(!binaryAvailable())("qube build", () => {
  test.failing("writes target/debug/<name>.wasm by default, exit 0", () => {
    const proj = appProject();
    const r = runCli(["build"], { cwd: proj });
    expect(r.exitCode).toBe(0);
    expect(existsSync(join(proj, "target/debug/dev.q64.test_app.wasm"))).toBe(true);
  });

  test.failing("--release writes target/release/<name>.wasm", () => {
    const proj = appProject();
    const r = runCli(["build", "--release"], { cwd: proj });
    expect(r.exitCode).toBe(0);
    expect(existsSync(join(proj, "target/release/dev.q64.test_app.wasm"))).toBe(true);
  });

  test.failing("--component also writes a <name>.component.wasm", () => {
    const proj = appProject();
    runCli(["build", "--component"], { cwd: proj });
    expect(existsSync(join(proj, "target/debug/dev.q64.test_app.component.wasm"))).toBe(true);
  });

  test.failing("--debug builds into target/debug (unoptimised), exit 0", () => {
    const proj = appProject();
    const r = runCli(["build", "--debug"], { cwd: proj });
    expect(r.exitCode).toBe(0);
    expect(existsSync(join(proj, "target/debug/dev.q64.test_app.wasm"))).toBe(true);
  });

  test.failing("--target <name> selects a named target from the manifest, exit 0", () => {
    const proj = makeProject({
      "qube.json5": '{ "name": "dev.q64.test_app", "version": "0.1.0", "license": "MIT", "type": "application", "entry": "src/main.q", "targets": { "desktop": { "host": "wasmtime" } } }',
      "src/main.q": "fn main { env.out(\"x\") }\n",
    });
    expect(runCli(["build", "--target", "desktop"], { cwd: proj }).exitCode).toBe(0);
  });

  test.failing("a compile error from q64 propagates as exit 64", () => {
    const proj = makeProject({
      "qube.json5": appManifest(),
      "src/main.q": "import q64.math.*\nfn main { env.out(\"x\") }\n",
    });
    expect(runCli(["build"], { cwd: proj }).exitCode).toBe(64);
  });
});
