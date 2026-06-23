# q64/src/codegen

AST → Wasm 3.0 emission. Uses the Binaryen C API.

> **Status: source-driven emission running.** `emit.zig` parses a
> q64 source file, walks `fn main`, and emits a wasm module with
> the program's `env.out("…")` calls laid out in linear memory.
> `q64 emit <file.q> <out.wasm>` then `q64-wasmtime-host out.wasm`
> prints the program's output. `emit.emitHelloWasm` is kept as a
> hand-built fixture for regression testing.

## Scope

**Owns:**
- AST/TIR → Wasm 3.0 binary emission via Binaryen.
- Wasm 3.0 feature lowering: Memory64, multi-memory, table64,
  WasmGC, threads + atomics, stack-switching, SIMD.
- Region allocator codegen — emits the bump / pool / free-list /
  stack / GC allocator that backs each region kind.
- Cross-heap transfer codegen (explicit copies between linear and
  managed memory).
- Custom wasm sections for graph topology, effect declarations, and
  capability needs (per [`design.md`](https://github.com/q64-lang/design/blob/main/design.md)
  §"Inspection and Introspection").
- Link-step assembly: combine module-local wasm into the final
  artifact, dedupe imports, finalize memory and table sizes.

**Does not own:**
- Type checking, region analysis, effect propagation — already done
  upstream.
- Host glue — `runtime/<host>/` provides the Zig adapter that
  imports into the emitted wasm.

## Inputs / outputs

- **In (today):** parsed source via `emitFromSource(allocator,
  source, file)` — finds `fn main`, walks its body, emits a wasm
  module. Only `env.out("…")` calls are recognized; everything else
  is `Error.UnsupportedExpression`.
- **In (eventually):** fully-checked AST/TIR from `effect/` (the
  last semantic pass).
- **Out:** `.wasm` bytes. Future: sidecar `.effects.json` /
  `.graph.json` for `qube` to consume; diagnostics with `CGN*` and
  `LNK*` codes.

## Files

| File         | Status          | Purpose                                                   |
|-----------------|----------|------------------------------------------------------------------|
| `emit.zig`      | partial  | Binaryen bindings, `emitFromSource`, `emitComponent`, `emitHelloWasm`. |
| `component.zig` | v0 slice | Pure-Zig WebAssembly **component** encoder for the import-free **library** lift — wraps the core module in a component whose WIT world is the synthesized scalar (`s64`/`bool`/`f64`) export surface. An **app** (one that reaches `@stdout`) isn't encoded here: `emit.zig` emits it as a WASI **preview1** core (`env.out` → `wasi_snapshot_preview1.fd_write`, `StdoutAbi.wasi_preview1`) and the CLI runs `wasm-tools component new --adapt` (vendor/wasi/) to lift it into a `wasi:cli/run` command importing `wasi:cli/stdout`. Library components are validated + called via `q64-component-check`; an app is run with the vendored wasmtime CLI under the async WASIp3 runtime (`wasmtime run -S p3`). |

## Capability lowering: `env.kv` → `wasi:keyvalue` (in progress)

Beyond `@stdout` (preview1 → `wasi:cli/run`), a capability face becomes a
component **import** the host supplies (spec/env.md §"Env ↔ WASI Preview 3").
`env.kv` is the first key-value lowering. Two distinct core ABIs come from one
source, picked by target — exactly like `StdoutAbi`:

- **local `qube run`** — the core imports q64's raw `env.kv_increment` face; the
  vendored wasmtime host serves it directly (no component).
- **`--component`** — the core imports the **canonical** `wasi:keyvalue` core ABI
  (`wasm-tools` `cm32p2|wasi:keyvalue/store@0.2.0-draft2#open` +
  `…/atomics@…#increment`), then `emit.zig` shells out to `wasm-tools component
  embed` (with the vendored `wit/wasi-keyvalue.wit` dep) + `component new` to lift
  it — the same shape as the `--adapt` path.

The component lowering pins:

- **adapter-held bucket** — `store.open` is the *host's* step, called lazily with
  an empty identifier; the host pins the bucket to the qube's identity. The handle
  is cached in a module global, so the qube never names a namespace.
- **canonical result layout** — `open → result<bucket,error>` lands `{disc:u8 @0,
  handle:i32 @4}`; `increment → result<s64,error>` lands `{disc:u8 @0, s64 @8}`.
- **required exports** — `cm32p2_memory`, `cm32p2_realloc`, `cm32p2_initialize`;
  exports named `cm32p2||<name>`.

The byte-exact target is the design of record in
[`../../test/kv-component-reference/`](../../test/kv-component-reference/) — a
hand-written reference core + `run.sh` that builds and validates the component
through `wasm-tools`, independent of the q64 build. `src/codegen/wit/` holds the
vendored `wasi:keyvalue` WIT dep the emit shells out with.

## External

- **Binaryen** — Wasm 3.0 backend, called via its C API. Vendored
  at `../../vendor/binaryen/` by `init.sh` (pinned version 129 with
  sha256 verification). Static-linked into the `q64` binary.

Binaryen ships only a static archive on Linux, built against
libstdc++ (gcc CI). The build script pulls in `libstdc++.so.6`
and `libgcc_s.so.1` from the system to satisfy the C++ runtime
and unwinder symbols.
