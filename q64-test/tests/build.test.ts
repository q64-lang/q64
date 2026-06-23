/**
 * `q64 build <file>` (spec §Subcommands) compiles to wasm and emits
 * `<file>.wasm` or `--out <path>`. The implemented v0 spelling is
 * `q64 emit <file.q> <out.wasm> [--module name=dir ...]`; the spec'd
 * `build` surface and its flags are encoded as `.todo` until they land.
 */
import { tmpdir } from "node:os";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { WASM_MAGIC, binaryAvailable, fixture, runCli, tmpCopy } from "../src/harness";

let work: string;
beforeAll(() => {
  work = mkdtempSync(join(tmpdir(), "q64-build-"));
});
afterAll(() => {
  if (work) rmSync(work, { recursive: true, force: true });
});

describe.skipIf(!binaryAvailable())("q64 emit (implemented build surface)", () => {
  test("emits a wasm module starting with the \\0asm magic, exit 0", () => {
    const out = join(work, "hello.wasm");
    const r = runCli(["emit", fixture("hello.q"), out]);
    expect(r.exitCode).toBe(0);
    expect(existsSync(out)).toBe(true);
    expect(readFileSync(out).subarray(0, 4)).toEqual(WASM_MAGIC);
  });

  test("a module-level actor singleton emits valid wasm and shares state across calls", async () => {
    // `let twin = Counter.spawn()` is a module-lifetime instance: its state is
    // allocated once by the wasm `start` and kept in a global, so the shared
    // count advances across calls (1, 2, 3) — the heap singleton, end to end.
    const out = join(work, "singleton.wasm");
    const r = runCli(["emit", fixture("singleton.q"), out, "--addr", "wasm32"]);
    expect(r.exitCode).toBe(0);
    expect(readFileSync(out).subarray(0, 4)).toEqual(WASM_MAGIC);
    const { instance } = await WebAssembly.instantiate(readFileSync(out), {});
    const ping = instance.exports.ping as () => bigint;
    expect(ping()).toBe(1n);
    expect(ping()).toBe(2n);
    expect(ping()).toBe(3n);
  });

  test("a @channel_handler emits a session entry point driven by host imports", async () => {
    // The remote channel seam: `for _ in session` is `env.channel_recv` (1 = a
    // message arrived, 0 = closed) and `session.send` is `env.channel_send`.
    // Drive it with a host that delivers three messages then closes; the handler
    // must send once per message and stop on close.
    const out = join(work, "channel-handler.wasm");
    const r = runCli(["emit", fixture("channel-handler.q"), out, "--addr", "wasm32"]);
    expect(r.exitCode).toBe(0);
    const mod = new WebAssembly.Module(readFileSync(out));
    expect(WebAssembly.Module.imports(mod).map((i) => `${i.module}.${i.name}`).sort()).toEqual([
      "env.channel_recv",
      "env.channel_send",
    ]);
    let inbound = 3; // three taps, then the peer closes
    const sent: bigint[] = [];
    const instance = await WebAssembly.instantiate(mod, {
      env: {
        channel_recv: (_session: bigint) => (inbound-- > 0 ? 1n : 0n),
        channel_send: (_session: bigint, value: bigint) => void sent.push(value),
      },
    });
    (instance.exports.pump as (session: bigint) => void)(7n);
    expect(sent).toEqual([1n, 1n, 1n]); // one send per received tap, then stop
  });

  test("missing source file: non-zero exit", () => {
    const r = runCli(["emit", fixture("nope.q"), join(work, "x.wasm")]);
    expect(r.exitCode).not.toBe(0);
  });

  test("missing output argument: usage error, exit 2", () => {
    const r = runCli(["emit", fixture("hello.q")]);
    expect(r.exitCode).toBe(2);
  });

  test("--module expects name=dir; malformed mapping is a usage error", () => {
    const r = runCli(["emit", fixture("hello.q"), join(work, "x.wasm"), "--module", "bogus"]);
    expect(r.exitCode).toBe(2);
  });
});

// Test-first: the spec's `build` surface (distinct from the v0 `emit` spelling).
// Not implemented yet, so these are `test.failing` until `build` lands.
describe.skipIf(!binaryAvailable())("q64 build (spec surface)", () => {
  test.failing("build <file> writes <file>.wasm by default", () => {
    const src = tmpCopy("hello.q");
    const r = runCli(["build", src]);
    expect(r.exitCode).toBe(0);
    expect(existsSync(`${src}.wasm`)).toBe(true);
  });

  test.failing("--out <path> overrides the output path", () => {
    const out = join(work, "custom.wasm");
    const r = runCli(["build", fixture("hello.q"), "--out", out]);
    expect(r.exitCode).toBe(0);
    expect(existsSync(out)).toBe(true);
  });

  test.failing("--component also writes <out>.component.wasm", () => {
    const out = join(work, "comp.wasm");
    const r = runCli(["build", fixture("hello.q"), "--out", out, "--component"]);
    expect(r.exitCode).toBe(0);
    expect(existsSync(`${out}.component.wasm`)).toBe(true);
  });

  test.failing("--target <name> resolves and builds", () => {
    expect(runCli(["build", fixture("hello.q"), "--target", "wasmtime", "--out", join(work, "t.wasm")]).exitCode).toBe(0);
  });

  test.failing("compile error exits 64 (per §Exit codes)", () => {
    expect(runCli(["build", fixture("parse-error.q"), "--out", join(work, "e.wasm")]).exitCode).toBe(64);
  });
});
