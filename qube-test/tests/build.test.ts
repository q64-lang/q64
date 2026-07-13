/**
 * `qube build [--component] [--addr <addr>] [--release]` (spec/qube-cli.md
 * §Subcommands, §"Build outputs"). Compiles the qube to wasm by delegating to
 * `q64 emit`, writing `target/<profile>/<addr>/<name>.wasm` (and, with
 * `--component`, `<name>.component.wasm`).
 *
 * These really compile, so they need the `q64` binary built; gated on
 * `q64Available()` and pass `Q64_BIN` through to the spawned qube. There is NO
 * default address space: a build resolves it from --addr or the selected
 * --target's `addressSpace` and errors when neither is set (spec/qube-cli.md
 * §"Global options"). End-to-end component validation (wasmtime instantiating
 * + calling the lifted exports) lives in scripts/component-roundtrip.sh.
 */
import { existsSync, readFileSync } from "node:fs";
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
  test("--addr wasm64 writes target/debug/wasm64/<name>.wasm, exit 0", () => {
    const proj = appProject();
    const r = runCli(["build", "--addr", "wasm64"], { cwd: proj, env });
    expect(r.exitCode).toBe(0);
    expect(existsSync(join(proj, "target/debug/wasm64/dev.q64.test_app.wasm"))).toBe(true);
  });

  test("--release writes target/release/<addr>/<name>.wasm", () => {
    const proj = appProject();
    const r = runCli(["build", "--release", "--addr", "wasm64"], { cwd: proj, env });
    expect(r.exitCode).toBe(0);
    expect(existsSync(join(proj, "target/release/wasm64/dev.q64.test_app.wasm"))).toBe(true);
  });

  test("--target selects addr and output dir from the manifest's targets map", () => {
    const proj = makeProject({
      "qube.json5":
        '{ "name": "dev.q64.test_app", "version": "0.1.0", "license": "MIT", "type": "application", "entry": "src/main.q", "targets": { "desktop": { "host": "wasmtime", "addressSpace": "wasm32" } } }',
      "src/main.q": 'fn main { env.out("x") }\n',
    });
    const r = runCli(["build", "--target", "desktop"], { cwd: proj, env });
    expect(r.exitCode).toBe(0);
    expect(existsSync(join(proj, "target/desktop/wasm32/dev.q64.test_app.wasm"))).toBe(true);
  });

  test("--addr wasm32 selects the address-space subdir", () => {
    const proj = appProject();
    const r = runCli(["build", "--addr", "wasm32"], { cwd: proj, env });
    expect(r.exitCode).toBe(0);
    expect(existsSync(join(proj, "target/debug/wasm32/dev.q64.test_app.wasm"))).toBe(true);
  });

  test("--component on a scalar library also writes <name>.component.wasm", () => {
    const proj = scalarLibProject();
    const r = runCli(["build", "--component", "--addr", "wasm64"], { cwd: proj, env });
    expect(r.exitCode).toBe(0);
    expect(existsSync(join(proj, "target/debug/wasm64/dev.q64.math.wasm"))).toBe(true);
    expect(existsSync(join(proj, "target/debug/wasm64/dev.q64.math.component.wasm"))).toBe(true);
  });

  test("--component also writes <name>.wit, world named from the manifest wit block (WIT rung 2)", () => {
    // With no wit block, the world defaults to the last segment of `name`
    // (`math`) and the package derives from it — NOT the entry filename (`lib`).
    const proj = scalarLibProject();
    const r = runCli(["build", "--component", "--addr", "wasm64"], { cwd: proj, env });
    expect(r.exitCode).toBe(0);
    const witPath = join(proj, "target/debug/wasm64/dev.q64.math.wit");
    expect(existsSync(witPath)).toBe(true);
    const wit = readFileSync(witPath, "utf8");
    expect(wit).toContain("package dev-q64:math;");
    expect(wit).toContain("world math {");
    // Never the entry-filename-derived default.
    expect(wit).not.toContain("world lib {");
  });

  test("--component honors an explicit wit block (package + world)", () => {
    const proj = makeProject({
      "qube.json5":
        '{ "name": "dev.q64.math", "version": "0.1.0", "license": "MIT", "type": "library", "entry": "src/lib.q", "wit": { "package": "acme:calc", "world": "calculator" } }',
      "src/lib.q": "pub fn add(a: i64, b: i64) -> i64 { a + b }\n",
    });
    const r = runCli(["build", "--component", "--addr", "wasm64"], { cwd: proj, env });
    expect(r.exitCode).toBe(0);
    const wit = readFileSync(join(proj, "target/debug/wasm64/dev.q64.math.wit"), "utf8");
    expect(wit).toContain("package acme:calc;");
    expect(wit).toContain("world calculator {");
  });

  test.skipIf(!componentToolsAvailable())(
    "--component declares the manifest's wit.imports as a component import (WIT rung 5)",
    () => {
      const proj = makeProject({
        "qube.json5":
          '{ "name": "dev.q64.consumer", "version": "0.1.0", "license": "MIT", "type": "library", "entry": "src/lib.q", "component": { "emit": true }, "wit": { "package": "dev-q64:consumer", "world": "consumer", "imports": ["wit/math.wit"] } }',
        "wit/math.wit": "package acme:mathlib@1.0.0;\ninterface math { add: func(a: s64, b: s64) -> s64; }\n",
        "src/lib.q": "pub fn compute(x: i64) -> i64 { x + 1 }\n",
      });
      const r = runCli(["build", "--component", "--addr", "wasm64"], { cwd: proj, env });
      expect(r.exitCode).toBe(0);
      const comp = join(proj, "target/debug/wasm64/dev.q64.consumer.component.wasm");
      expect(existsSync(comp)).toBe(true);
      // wasm-tools agrees: the component imports the foreign interface and
      // exports the q64 function.
      const wit = Bun.spawnSync({ cmd: [WASM_TOOLS, "component", "wit", comp] }).stdout.toString();
      expect(wit).toContain("import acme:mathlib/math@1.0.0");
      expect(wit).toContain("export compute: func(x: s64) -> s64");
    },
  );

  test("a compile error from q64 propagates as exit 64", () => {
    const proj = makeProject({
      "qube.json5": appManifest(),
      "src/main.q": "import q64.math.*\nfn main { env.out(\"x\") }\n",
    });
    expect(runCli(["build", "--addr", "wasm64"], { cwd: proj, env }).exitCode).toBe(64);
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

// Strict option parsing needs only the qube binary — every case errors before
// `q64` would be spawned.
describe.skipIf(!binaryAvailable())("qube build (option parsing)", () => {
  test("no --addr and no --target → usage error, exit 2 (no default address space)", () => {
    const r = runCli(["build"], { cwd: appProject() });
    expect(r.exitCode).toBe(2);
    expect(r.stderr).toContain("no address space");
  });

  test("an unknown option → usage error, exit 2 (never warn-and-ignore)", () => {
    const r = runCli(["build", "--frobnicate"], { cwd: appProject() });
    expect(r.exitCode).toBe(2);
    expect(r.stderr).toContain("unknown option");
  });

  test("a spec'd-but-unimplemented global flag errors honestly, exit 2", () => {
    const r = runCli(["build", "--frozen"], { cwd: appProject() });
    expect(r.exitCode).toBe(2);
    expect(r.stderr).toContain("not implemented");
  });

  test("--target without addressSpace and no --addr → input error, exit 65", () => {
    const proj = makeProject({
      "qube.json5":
        '{ "name": "dev.q64.test_app", "version": "0.1.0", "license": "MIT", "type": "application", "entry": "src/main.q", "targets": { "desktop": { "host": "wasmtime" } } }',
      "src/main.q": 'fn main { env.out("x") }\n',
    });
    expect(runCli(["build", "--target", "desktop"], { cwd: proj }).exitCode).toBe(65);
  });

  test("--target naming no manifest target → input error, exit 65", () => {
    expect(runCli(["build", "--target", "nope"], { cwd: appProject() }).exitCode).toBe(65);
  });
});
