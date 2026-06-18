# TODO: q64 codegen in the browser (WASM)

**Goal.** Run the *full* q64 compiler — including codegen (`emit`) — as
WebAssembly, so a host (browser, iOS WKWebView, Android WebView) can compile
`.q` → wasm **entirely client-side, no server**. Today only the *analysis* core
runs in wasm; codegen is the missing half.

## Current state (verified)

- [`q64-lsp/packages/core-wasm`](../q64-lsp/packages/core-wasm) → `q64-core.wasm`:
  parser/analysis only, **pure Zig, never links Binaryen**. ✅ runs in a browser.
- [`q64/src/codegen/emit.zig`](../q64/src/codegen) uses the **Binaryen C API**
  (static `libbinaryen.a`, built natively by `init.sh`). This C++ dependency is
  the blocker for wasm codegen.
- `qube` drives builds by **spawning `q64` as a subprocess** — impossible on a
  device (no `fork`/`exec`) and in a browser.

## The crux: Binaryen in wasm

Binaryen is C++. Three ways to get codegen into wasm, roughly increasing effort:

### Option A — Binaryen → `wasm32-wasi` static lib, linked into a q64 wasm
Mirror the native build: `q64/build.zig` already links `libbinaryen.a`; produce
that archive for `wasm32-wasi` and add a `q64-emit.wasm` target.
- Build Binaryen for `wasm32-wasi`: **single-threaded** (wasm threads need
  shared memory + workers — skip for v1), **C++ exceptions** via wasm-eh
  (`-fwasm-exceptions`), libc++ from wasi-sdk *or* Zig-as-compiler
  (`zig c++ -target wasm32-wasi`) driving Binaryen's sources.
- New target (sibling to core-wasm): `q64-emit.wasm` = codegen modules +
  Binaryen archive, exporting a C ABI `compile(ptr,len) -> (outPtr<<32)|outLen`
  plus the existing diagnostics envelope.
- **Risks:** the Binaryen wasi build (exceptions/threads/libc++), wasm size
  (Binaryen is large — expect multi-MB; `ReleaseSmall`, lazy-load), interpreter
  vs JIT perf.

### Option B — Binaryen as a host import (`binaryen.js`)
Keep q64 codegen as wasm, but route its Binaryen C API calls to **host
functions backed by the existing, maintained `binaryen.js`**. q64 codegen wasm
imports `binaryen_*` shims; the JS host wires them to binaryen.js.
- **Pros:** reuse maintained binaryen.js; no Binaryen-wasi build.
- **Cons:** marshal the C API subset across the boundary (handles/pointers);
  host must be JS (fine for a WebView; not for a pure native wasm runtime).

### Option C — pure-Zig wasm emitter (no Binaryen)
Replace Binaryen with a Zig wasm encoder (instruction selection + binary
encoding), non-optimizing v1.
- **Pros:** compiler becomes **100% pure Zig** → native + wasm + everywhere, no
  C++. The same reason analysis already runs in wasm.
- **Cons:** large reimplementation; lose Binaryen's optimization + validation;
  long correctness tail.

## Recommendation

1. **Spike Option A first** (timeboxed): *can Binaryen build for `wasm32-wasi`
   at all* (single-threaded, exceptions)? That answers feasibility fastest and
   reuses the existing link path.
2. If A's size/threads/exceptions prove painful, fall back to **B**
   (`binaryen.js` host import) for the browser specifically.
3. Hold **C** (pure-Zig emitter) as the strategic north star for zero-C++
   portability if/when we want to drop the Binaryen dependency entirely.

## Required regardless of option: subprocess → in-process

On a device/browser there is no `fork`/`exec`. `qube` must invoke the compiler
**in-process** — the `qube build --in-process` mode already noted in
[`ARCHITECTURE.md`](../ARCHITECTURE.md). Link `q64` as a library / call a
`compile()` entry instead of spawning. Gating task for *any* on-device or
in-browser build.

## Checklist

- [ ] Spike: Binaryen builds for `wasm32-wasi` (single-threaded, `-fwasm-exceptions`)
- [ ] `libbinaryen.a` (wasm) reproducible from `init.sh` (pinned artifact or Zig-built)
- [ ] `q64-emit.wasm` target exporting `compile()` C ABI + diagnostics envelope
- [ ] Differential test: in-wasm `emit` vs native `q64 emit` over the test corpus
- [ ] `qube build --in-process` (no subprocess)
- [ ] On device, skip `--component` (it shells out to `wasm-tools`) — emit a bare
      core module; the pure-Zig `component.zig` covers the simple cases
- [ ] Size budget: `ReleaseSmall`, lazy-load the compiler wasm
- [ ] Threads: single-threaded v1; revisit SharedArrayBuffer + workers later

## Downstream: hosting the wasm on iPad / Android

(For consumers like Qubonaut — both the *compiler* wasm and the *compiled
program* wasm.)

**Principle: the WebView is the common wasm host.** WKWebView (iOS) and Android
System WebView both ship a JIT JS engine + WebAssembly + WebGPU. Write the host
once (reuse [`runtime/web-retained`](../runtime/web-retained) for UI) and run on
both.

- **iPad / iOS:** WKWebView is the **only JIT-allowed** engine → fastest wasm +
  WebGPU. Host the compiler wasm *and* the compiled program here. JIT-free
  native runtimes (WasmKit pure-Swift, wasmtime **Pulley** interpreter) are a
  slow fallback for headless / no-WebView cases only.
- **Android:** no JIT restriction. The same WebView path works (max code reuse
  with iOS). For headless/perf a native JIT wasm runtime (Wasmtime/WAMR via JNI,
  or Chicory pure-JVM) is allowed and faster than an interpreter — optional.
- **Compiler hosting:** the compiler-in-wasm is large and wants speed → host it
  in the WebView (JIT) on both platforms, same path as running the output.
- **UI output:** WebGPU via `runtime/web-retained` (proven on iPad).
- **Headless output / stdout:** `runtime/browser` `env.out` in the WebView, or a
  native runtime.

**Net:** one WebView-based wasm host, shared iOS + Android, runs both the q64
compiler-wasm and the compiled qube-wasm. Native wasm runtimes are optional
platform add-ons (iOS limited to an interpreter; Android free to use a full JIT
runtime).
