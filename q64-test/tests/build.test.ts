/**
 * `q64 build <file>` (spec §Subcommands) compiles to wasm and emits
 * `<file>.wasm` or `--out <path>`. The implemented v0 spelling is
 * `q64 emit <file.q> <out.wasm> [--module name=file ...]`; the spec'd
 * `build` surface and its flags are encoded as `.todo` until they land.
 *
 * `--module name=<path>` maps to the dependency's entry *source file* (e.g.
 * `…/src/lib.q`) — `qube` resolves it from the manifest `entry`; the compiler
 * reads exactly that file and never guesses a filename (spec/q64-cli.md
 * §"--module").
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

  test("connect<…>() opens a session and for n in twin drains the inbound stream", async () => {
    // The importer side of a remote channel: `connect` → env.channel_connect,
    // `for n in twin` → env.channel_recv (1 = message, 0 = closed) + a value
    // read via env.channel_take. Deliver three values then close; the module
    // `state` ends on the last one.
    const out = join(work, "connect.wasm");
    const r = runCli(["emit", fixture("connect.q"), out, "--addr", "wasm32"]);
    expect(r.exitCode).toBe(0);
    const mod = new WebAssembly.Module(readFileSync(out));
    expect(WebAssembly.Module.imports(mod).map((i) => `${i.module}.${i.name}`).sort()).toEqual([
      "env.channel_connect",
      "env.channel_recv",
      "env.channel_take",
    ]);
    const recv = [1n, 1n, 1n, 0n]; // three messages, then closed
    const take = [10n, 20n, 30n];
    let ri = 0;
    let ti = 0;
    const instance = await WebAssembly.instantiate(mod, {
      env: {
        channel_connect: () => 42n,
        channel_recv: (_h: bigint) => recv[ri++],
        channel_take: (_h: bigint) => take[ti++],
      },
    });
    (instance.exports._start as () => void)();
    expect((instance.exports.last as () => bigint)()).toBe(30n); // the last delivered value
  });

  test("the twin-counter frontend qube emits as written and drives both wires", async () => {
    // The full importer qube (the example's frontend.q): `import counter.{join}`
    // resolves against the backend (the `counter` qube) via --module; every
    // construct compiles — connect, the spawned redraw loop (`for n in twin`),
    // the press loop (`for _press in presses()`), `twin.send(Tap)`, qview paints.
    const out = join(work, "twin-frontend.wasm");
    const r = runCli([
      "emit",
      fixture("twin-frontend.q"),
      out,
      "--addr",
      "wasm32",
      "--module",
      // Map the `counter` module to its entry source file (spec/q64-cli.md
      // §"--module": a file, not a directory — the compiler never guesses).
      `counter=${fixture("counter-mod/lib.q")}`,
    ]);
    expect(r.exitCode).toBe(0);
    const mod = new WebAssembly.Module(readFileSync(out));
    const imports = WebAssembly.Module.imports(mod).map((i) => `${i.module}.${i.name}`);
    expect(imports).toContain("env.channel_connect"); // connect<counter.join>()
    expect(imports).toContain("env.channel_take"); // for n in twin (value)
    expect(imports).toContain("env.presses"); // for _press in presses()
    expect(imports).toContain("env.channel_send"); // twin.send(Tap)

    // Drive it: the twin broadcasts two counts (the spawned redraw loop), then
    // the user presses twice and closes — each press sends a unit Tap up.
    const recvTwin = [1n, 1n, 0n];
    const take = [1n, 2n];
    const recvPress = [1n, 1n, 0n];
    let rt = 0;
    let ti = 0;
    let rp = 0;
    const paints: number[] = [];
    const taps: bigint[] = [];
    const instance = await WebAssembly.instantiate(mod, {
      env: {
        channel_connect: () => 7n,
        presses: () => 9n,
        channel_recv: (h: bigint) => (h === 9n ? recvPress[rp++] : recvTwin[rt++]),
        channel_take: (_h: bigint) => take[ti++],
        channel_send: (_h: bigint, v: bigint) => void taps.push(v),
      },
      qview: {
        text: () => {},
        number: (_x: number, _y: number, n: bigint) => paints.push(Number(n)),
        button: () => {},
        present: () => {},
      },
    });
    (instance.exports._start as () => void)();
    expect(paints).toEqual([1, 2]); // redrew on each broadcast
    expect(taps).toEqual([0n, 0n]); // a unit Tap per press
    expect((instance.exports.count as WebAssembly.Global).value).toBe(2n);
  });

  test("--asyncify lets a channel handler park at channel_recv and resume per message", async () => {
    // The live `@channel_handler` loop: `q64 emit … --asyncify` runs Binaryen's
    // asyncify pass so the host can suspend the wasm at `env.channel_recv` (no
    // message yet) and rewind it when one arrives — `for _ in session` becomes a
    // real coroutine that parks between messages. Drive `pump` (each inbound
    // message → one send) through suspend/resume.
    const out = join(work, "pump-async.wasm");
    const r = runCli(["emit", fixture("channel-handler.q"), out, "--addr", "wasm32", "--asyncify"]);
    expect(r.exitCode).toBe(0);
    const mod = new WebAssembly.Module(readFileSync(out));
    const exportNames = WebAssembly.Module.exports(mod).map((e) => e.name);
    // The asyncify pass added the control surface.
    expect(exportNames).toContain("asyncify_start_unwind");
    expect(exportNames).toContain("asyncify_get_state");

    const NORMAL = 0;
    const UNWINDING = 1;
    const REWINDING = 2;
    const sent: bigint[] = [];
    let resumeVal = 0n;
    let exp: any;
    const instance = await WebAssembly.instantiate(mod, {
      env: {
        channel_send: (_s: bigint, v: bigint) => void sent.push(v),
        channel_recv: (_s: bigint): bigint => {
          if (exp.asyncify_get_state() === REWINDING) {
            exp.asyncify_stop_rewind();
            return resumeVal; // the message we're resuming with
          }
          exp.asyncify_start_unwind(DATA); // no message → park the whole handler
          return 0n;
        },
      },
    });
    exp = instance.exports;

    // The asyncify stack lives high in page 0 (the handler's own arena is tiny).
    const DATA = 0x9000;
    const STACK = 0x2000;
    const dv = new DataView((exp.memory as WebAssembly.Memory).buffer);
    dv.setUint32(DATA, DATA + 8, true);
    dv.setUint32(DATA + 4, DATA + 8 + STACK, true);

    // Start: no message yet → the handler parks at the first recv.
    exp.pump(1n);
    expect(exp.asyncify_get_state()).toBe(UNWINDING);
    exp.asyncify_stop_unwind();
    expect(sent.length).toBe(0);

    // Deliver three messages; each rewinds into recv (returns 1), sends, then
    // parks again at the next recv.
    for (let i = 0; i < 3; i++) {
      resumeVal = 1n;
      exp.asyncify_start_rewind(DATA);
      exp.pump(1n);
      if (exp.asyncify_get_state() === UNWINDING) exp.asyncify_stop_unwind();
    }
    expect(sent).toEqual([1n, 1n, 1n]); // one send per resumed message
  });

  test("missing source file: non-zero exit", () => {
    const r = runCli(["emit", fixture("nope.q"), join(work, "x.wasm")]);
    expect(r.exitCode).not.toBe(0);
  });

  test("missing output argument: usage error, exit 2", () => {
    const r = runCli(["emit", fixture("hello.q")]);
    expect(r.exitCode).toBe(2);
  });

  test("--module expects name=file; malformed mapping is a usage error", () => {
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
