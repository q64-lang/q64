# q64/src/ir

The two-tier **Q64 IR** and the passes that build and lower it. This is the
layer that makes good on the architectural decision that *language semantics
must not depend on a backend's IR*: the compiler lowers to its own IR first,
and only `codegen/` turns that into Binaryen/WASM.

> **Status: the sole emission path.** [`codegen/emit.zig`](../codegen/emit.zig)
> lowers `AST → HIR → MIR → Binaryen` and nothing else — the interim direct
> `AST → Binaryen` emitter was removed once the IR covered the surface the
> compiler emits. Today the IR path handles `fn main` with `env.out(…)` of
> constants, runtime str values (calls + bindings + interpolation), and i64
> values (calls + bindings + interpolation), plus the i64 functions (with
> arithmetic, control flow, and recursion) and str functions (const/pass-
> through/concat bodies) it transitively calls, and main-less twins (`state`
> globals + exported handlers). A construct it doesn't represent yet is an
> honest `UnsupportedExpression`; definite semantic errors surface as their
> diagnostic codes (`build_hir`'s `Reject` → codegen `mapReject`).

## The two tiers

| Tier | File | "…" | Holds |
|------|------|-----|-------|
| **HIR** — Semantic QIR | [`hir.zig`](./hir.zig) | what the program *means* | name-resolved, desugared; types/regions/effects annotated by the semantic passes; abstract `str`; the pub surface + capability set for the component/WIT lift |
| **MIR** — Executable QIR | [`mir.zig`](./mir.zig) | how it *executes* | ABI-lowered: `str` = `(ptr, len)`, explicit region/`alloc` ops, structured (wasm-shaped) control flow, the static memory image. The single input a backend consumes |

### Control flow & the CFG escape hatch

MIR control flow is **structured** (`block`/`if`/`loop`/`br`) — it matches the
WASM target and the existing emitters, so lowering to Binaryen is near-1:1.
But `mir.Func.body` is form-agnostic:

```
Body = union { structured: *Inst, cfg: *Cfg }
```

The `cfg` arm is the explicit escape hatch — a basic-block form (`BasicBlock` +
`Terminator`) that a future relooper or LLVM/native backend can consume. Both
forms **reuse the same value `Inst`s**; only the control-flow skeleton differs,
so adding the CFG form never reshapes the rest of MIR. Nothing produces `cfg`
today and the WASM backend rejects it (`Error.CfgUnsupported`); the structured↔
CFG converter would live at this seam.

## Passes

- [`build_hir.zig`](./build_hir.zig) — **AST → HIR**. Imports `parser`; owns
  desugaring, name resolution, (eventual) typing, and const-folding. Runs the
  effect pass before returning, so the HIR it hands back is effect-annotated.
- [`effects.zig`](./effects.zig) — **effect pass** (HIR → HIR). Infers each
  function's capability set (`hir.Effect`, spec/effects.md): walks bodies for
  host faces (`env.out` → `@stdout`, `qview.*` → `@ui`), unions callee sets up
  the call graph to a fixpoint, and closes implications (`@stdout` ⇒ `@io`).
  The component/WIT lift reads the result as a function's imports; `q64 show
  effects|capabilities|world` print it.
- [`lower.zig`](./lower.zig) — **HIR → MIR**. Makes the `str` ABI, the region/
  allocator model, and int→string formatting explicit.
- [`print.zig`](./print.zig) — text dumps of either tier (golden tests +
  `q64 show hir|mir`); the HIR dump shows each function's visibility + effects.

## Neutrality invariant

**Nothing under `ir/` imports the Binaryen C API.** The IR is pure data; only
[`codegen/`](../codegen) links Binaryen and consumes MIR. This is enforced
structurally — `ir` unit tests build and run with no C++ link — and it is what
keeps a future second backend (`MIR → LLVM IR → native`) an *additive* change:
the same MIR feeds it. Allocation stays abstract in MIR (Memory64 + the arena
bump global are the Binaryen backend's realization, not baked in), and the
`env.*` capability faces are abstract host calls lowered per-backend (WASM
component imports today; a native host ABI later).

## Inputs / outputs

- **In:** `ast.SourceFile` from `parser/` (+ the `--module` map, as the IR path
  grows to resolve imports).
- **Out:** a `mir.Module` for `codegen/` to lower to Wasm; HIR metadata
  (visibility, effects) for the component/WIT + QubePod stages.

## Tests

Pure Zig, no Binaryen. Run via the `ir_tests` target inside
`vendor/zig/zig build --build-file q64/build.zig test`. The umbrella
[`lib.zig`](./lib.zig) pulls every submodule's embedded tests into that target.
