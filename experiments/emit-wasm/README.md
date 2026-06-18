# experiments/emit-wasm — q64 codegen → wasm (Option B spike)

Proves the **q64 half** of Option B (see [`../../docs/browser-codegen.md`](../../docs/browser-codegen.md)):
q64's codegen compiles to `wasm32-wasi` with **Binaryen unlinked**, so every
Binaryen C-API call becomes a wasm import that a JS host fills via `binaryen.js`.

## Result ✅

- Builds clean (`zig build`) → `zig-out/bin/q64-emit.wasm`.
- **Imports: 132 Binaryen functions** under `env` (full list in
  [`binaryen-imports.txt`](./binaryen-imports.txt)) + `wasi_snapshot_preview1`.
  Nothing else in `env`.
- Exports: `memory`, `q64_emit_len` (runs the full pipeline — parse → sema → ir →
  emit — on a tiny program, so the complete Binaryen surface is reachable).

The whole codegen pipeline (`emit.zig` + `parser`/`sema`/`ir`) compiles to wasm;
Binaryen is the only external dependency, and it's a clean, enumerable import set.

## Run

```sh
(cd ../.. && ./init.sh)          # once: vendors zig + builds vendor/binaryen
../../vendor/zig/zig build       # → zig-out/bin/q64-emit.wasm
# size: add -Doptimize=ReleaseSmall
```

Uses `vendor/binaryen/include` for the **header only** — it never links
`libbinaryen.a` (that's the whole point).

## What's left for in-browser compile

1. **Real C ABI entry** — `compile(srcPtr, len) -> (outPtr<<32)|outLen` + a
   diagnostics envelope (replace the throwaway `q64_emit_len`).
2. **JS shim** — implement the 132 `env.Binaryen*` imports over `binaryen.js`:
   handle mapping (wasm i32 handles ↔ binaryen.js objects) + marshalling (read
   child arrays / strings out of wasm linear memory). Plus minimal
   `wasi_snapshot_preview1` stubs (the module is a reactor).
3. **`qube build --in-process`** — drive the compiler without a subprocess.

Then load `q64-emit.wasm` + `binaryen.js` in a WebView (WKWebView / Android
WebView) → compile `.q` on device, no server.
