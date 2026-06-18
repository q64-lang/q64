# experiments/emit-wasm — q64 codegen → wasm, on device (Option B)

The on-device q64 compiler: `q64-emit.wasm` is the **full** q64 codegen pipeline
(parse → sema → ir → emit) compiled to `wasm32-wasi` with **Binaryen unlinked**,
plus a JS host (`host/`) that fills Binaryen's C API from the maintained
[`binaryen.js`](https://www.npmjs.com/package/binaryen). Together they compile
`.q` → wasm **entirely client-side — no server, no subprocess** (the missing half
of edit→compile→run on iPad). See [`../../docs/browser-codegen.md`](../../docs/browser-codegen.md).

## Result ✅

- **`q64-emit.wasm`** (`zig build -Doptimize=ReleaseSmall`) exports a C ABI —
  `q64_alloc` / `q64_free` / `q64_compile` / `q64_diagnostics` (+ `q64_libc_malloc`
  for the result hand-off) — and imports exactly **132 `env.Binaryen*`** functions
  (full list in [`binaryen-imports.txt`](./binaryen-imports.txt)) plus three WASI
  stubs (`args_get`, `args_sizes_get`, `proc_exit`). Nothing else.
- **`host/`** implements those 132 imports over `binaryen.js@129` (pinned to the
  vendored Binaryen version) and drives the whole thing.
- **Differential test passes**: every `.q` in `examples/` + `spec/tests/` that
  compiles produces a core module **byte-identical** to native `q64 emit`, on both
  `wasm32` and `wasm64` (46 programs; the rest need `--module` or are
  negative-type fixtures both paths reject identically).

## ABI (mirrors `q64-lsp/packages/core-wasm`)

```
q64_alloc(len)                     -> ptr      ; host writes `len` source bytes
q64_compile(ptr, len, wasm64)      -> u64      ; (out_ptr<<32)|out_len of core .wasm, 0 on failure
q64_diagnostics(ptr, len, wasm64)  -> u64      ; (out_ptr<<32)|out_len of a spec/diagnostics.md JSON envelope
q64_free(ptr, len)                              ; release any buffer received
```

A bare **core module** is emitted (what the run / qview lanes consume) — never a
component (`--component` shells out to `wasm-tools`, impossible on device).

## How the shim works

`binaryen.js` is Binaryen compiled to wasm; it exposes the raw `_Binaryen*` C
functions and `_malloc`/`_free`, but not its HEAP views — so the shim captures
its `WebAssembly.Memory` by hooking `WebAssembly.instantiate` during load. Then:

- **Handles** (module / expression / type refs) are plain integers in both
  worlds → forwarded straight through (the pure-integer majority of the 132).
- **Pointers** (strings, type/operand arrays, the data segment, the literal
  struct, the emitted bytes) are marshalled between q64's heap and binaryen's
  heap by the ~20 special handlers in [`host/binaryen-shim.mjs`](./host/binaryen-shim.mjs).

It is isomorphic: the same `host/compiler.mjs` runs under Node (these tests) and
in a WebView (Qubonaut's `CompilerService`).

## Run

```sh
(cd ../.. && ./init.sh)                       # vendors zig + binaryen header/lib
zig build -Doptimize=ReleaseSmall             # → zig-out/bin/q64-emit.wasm
(cd host && npm install)                      # binaryen.js@129

# compile a .q with the in-wasm compiler
node host/compile.mjs path/to/foo.q -o foo.wasm

# prove it matches native q64 emit
node host/difftest.mjs ../../q64/zig-out/bin/q64 ../../examples/**/*.q
```

`zig build` uses `vendor/binaryen/include` for the **header only** — it never
links `libbinaryen.a`. That's the whole point: Binaryen stays an import set the
JS host fills.
