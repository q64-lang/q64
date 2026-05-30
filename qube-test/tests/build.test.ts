/**
 * `qube build [--component] [--addr <addr>] [--release]` (spec/qube-cli.md
 * §Subcommands, §"Build outputs"). Compiles the qube to wasm by delegating to
 * `q64 emit`, writing `target/<profile>/<addr>/<name>.wasm` (and, with
 * `--component`, `<name>.component.wasm`).
 *
 * These really compile, so they need the `q64` binary built; gated on
 * `q64Available()` and pass `Q64_BIN` through to the spawned qube. The default
 * address space is wasm64 (q64 emit's default). End-to-end component validation
 * (wasmtime instantiating + calling the lifted exports) lives in
 * scripts/component-roundtrip.sh.
 */
import { existsSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, test } from "bun:test";
import { Q64_BIN, WASI_ADAPTER, WASM_TOOLS, appManifest, binaryAvailable, componentToolsAvailable, makeProject, q64Available, runCli } from "../src/harness";

const env = { Q64_BIN, Q64_WASM_TOOLS: WASM_TOOLS, Q64_WASI_ADAPTER: WASI_ADAPTER };

function appProject() {
  return makeProject({ "qube.json5": appManifest(), "src/main.q": "fn main { env.out(\"x\") }\n" });
}

// A scalar library — its exports lift to a component with no capability imports
// (the slice `--component` handles today).
function scalarLibProject() {
  return makeProject({
    "qube.json5": '{ "name": "dev.q64.math", "version": "0.1.0", "license": "MIT", "type": "library", "entry": "src/lib.q" }',
    "src/lib.q": "pub fn add(a: i64, b: i64) -> i64 { a + b }\n",
  });
}

describe.skipIf(!binaryAvailable() || !q64Available())("qube build", () => {
  test("writes target/debug/<addr>/<name>.wasm by default, exit 0", () => {
    const proj = appProject();
    const r = runCli(["build"], { cwd: proj, env });
    expect(r.exitCode).toBe(0);
    expect(existsSync(join(proj, "target/debug/wasm64/dev.q64.test_app.wasm"))).toBe(true);
  });

  test("--release writes target/release/<addr>/<name>.wasm", () => {
    const proj = appProject();
    const r = runCli(["build", "--release"], { cwd: proj, env });
    expect(r.exitCode).toBe(0);
    expect(existsSync(join(proj, "target/release/wasm64/dev.q64.test_app.wasm"))).toBe(true);
  });

  test("--addr wasm32 selects the address-space subdir", () => {
    const proj = appProject();
    const r = runCli(["build", "--addr", "wasm32"], { cwd: proj, env });
    expect(r.exitCode).toBe(0);
    expect(existsSync(join(proj, "target/debug/wasm32/dev.q64.test_app.wasm"))).toBe(true);
  });

  test("--component on a scalar library also writes <name>.component.wasm", () => {
    const proj = scalarLibProject();
    const r = runCli(["build", "--component"], { cwd: proj, env });
    expect(r.exitCode).toBe(0);
    expect(existsSync(join(proj, "target/debug/wasm64/dev.q64.math.wasm"))).toBe(true);
    expect(existsSync(join(proj, "target/debug/wasm64/dev.q64.math.component.wasm"))).toBe(true);
  });

  test("a compile error from q64 propagates as exit 64", () => {
    const proj = makeProject({
      "qube.json5": appManifest(),
      "src/main.q": "import q64.math.*\nfn main { env.out(\"x\") }\n",
    });
    expect(runCli(["build"], { cwd: proj, env }).exitCode).toBe(64);
  });

  // `--component` on an *application* emits a WASI preview1 core (env.out →
  // fd_write) and adapts it into a real `wasi:cli/run` component via wasm-tools;
  // wasm32-only for now. Skipped when the WASI toolchain isn't vendored.
  test.skipIf(!componentToolsAvailable())("--component --addr wasm32 on an app emits the WASI component", () => {
    const proj = appProject();
    const r = runCli(["build", "--component", "--addr", "wasm32"], { cwd: proj, env });
    expect(r.exitCode).toBe(0);
    expect(existsSync(join(proj, "target/debug/wasm32/dev.q64.test_app.component.wasm"))).toBe(true);
  });

  // The 64-bit canonical ABI for the import lowering isn't supported yet, so
  // `--component` on a wasm64 app errors rather than mis-wrapping.
  test("--component on a wasm64 app errors (import lowering is wasm32-only)", () => {
    const proj = appProject();
    expect(runCli(["build", "--component", "--addr", "wasm64"], { cwd: proj, env }).exitCode).not.toBe(0);
  });
});
