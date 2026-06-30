# @q64/core-wasm

q64's analysis core, compiled to a single freestanding `q64-core.wasm`, with
TypeScript bindings.

## What it is

`build.zig` compiles q64's **analysis** Zig modules — `parser` **and** `sema`
(name resolution + the type/effect/region check pass) — for
`wasm32-freestanding` and exports a tiny C ABI. It **never links Binaryen** —
the analysis path is pure Zig, which is the whole reason the same source that
builds the native `q64` binary can also run in a browser, a Worker, or Node.

`q64_diagnose` runs the same pipeline as the native `q64 check`
(`q64/src/main.zig`): parse, then the sema passes, merging every
`LEX/PAR/NAM/TYP/EFF/REG/…` diagnostic into one envelope. The only check it
omits is NAM002 (a relative import escaping the qube), which needs to walk the
filesystem for the qube root — and the core has no disk.

> If this build ever needs Binaryen, an analysis module has wrongly grown a
> codegen dependency. Fix the dependency, not this package.

## ABI

| Export | Signature | Meaning |
|---|---|---|
| `q64_alloc` | `(len) -> ptr` | allocate `len` bytes; host writes source there |
| `q64_diagnose` | `(ptr, len) -> u64` | parse + sema check; returns `(out_ptr << 32) \| out_len` of a UTF-8 JSON envelope |
| `q64_hover` | `(ptr, len, off) -> u64` | symbol under byte `off` → `{"contents":"fn add(a: i64) -> i64"\|"local x"\|null}` |
| `q64_definition` | `(ptr, len, off) -> u64` | declaration of the symbol under byte `off` → `{"found":true,"offset":N,"len":M}` or `{"found":false}` |
| `q64_symbols` | `(ptr, len) -> u64` | file outline → `{"symbols":[{"name","kind","offset","len"},…]}` in declaration order |
| `q64_complete` | `(ptr, len, off) -> u64` | completion candidates → `{"items":[{"label","kind"},…]}` (top-level symbols + keywords) |
| `q64_free` | `(ptr, len)` | release a buffer (both the input and the returned output) |
| `memory` | — | the module's linear memory |

The JSON envelope matches [`spec/diagnostics.md`](../../../spec/diagnostics.md).

## Bindings

```ts
import { Core } from "@q64/core-wasm";
const core = await Core.load(wasmBytes);   // Node reads a file; browser fetches
const env = core.diagnose("fn main() {}\n");
//   { ok: true, diagnostics: [] }
```

`Core.load` takes raw bytes or a precompiled `WebAssembly.Module`, so the host
decides how the asset arrives. The bindings touch no DOM and no Node APIs.

## Build

```sh
pnpm build          # zig → q64-core.wasm, then tsc → dist/
pnpm run build:wasm # just the wasm
```

Verified: `parser` + `sema` compile clean to wasm32 (~188 KB ReleaseSmall) and
round-trip diagnostics from JS — including the semantic codes (e.g. a
`@realtime + @io` function flagged `EFF120`), not just lexer/parser errors.

## Roadmap

Diagnostics run the full check pipeline; `q64_hover` / `q64_definition` cover
**top-level** symbols (fn / struct / enum / const / …) **and locals** — params
and `let`/pattern bindings, via `sema.resolve`'s use→binding map. Functions
hover with their full signature (sliced verbatim from the CST); other symbols
hover as `kind name`. `q64_symbols` gives the file outline; `q64_complete`
offers top-level symbols, the enclosing function's locals (params + bindings),
and keywords. Still open:

- precise per-cursor completion scope — today locals are function-scoped (it
  may over-offer a sibling-block or below-cursor binding), and struct fields /
  member access (`a.field`) need the type checker;
- richer hover for non-functions — a struct's fields, a const's value/type;
- `q64_format` once `fmt` is wired in (for `textDocument/formatting`).

Each stays a pure `(source, position) -> JSON` query over the same parser + sema
modules — the query surface the LSP server consumes.
