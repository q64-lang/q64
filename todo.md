# todo

Active work tracker. Things to do, things to decide, kept short and
ticked off as they land. Long-form design questions live in
[`docs/history/MIGRATION.md`](./docs/history/MIGRATION.md); this file is
for items the next session should be able to pick up and act on.

## Compiler + linking — ACTIVE FOCUS (resuming after the weekend)

The registry and the package up/download loop are **done and live**. The
definition of done — `dev.q64.hello_app` prints `0.1.0` by calling
`dev.q64.hello_world.version()` — is **met** for the const-foldable case via
the linking ladder below. The test pair now lives in the repo at
`examples/link-demo/` (no longer ephemeral in `/tmp`).

Verify (builds q64 + host + qube, then exercises both `q64 emit --module`
and `qube run`):

```
./scripts/link-roundtrip.sh           # → PASS: 0.1.0
```

### Done this session (for the trail)
- [x] Registry: JSON5 manifest-read fix + publish-time name validation, deployed
      to `qubes.q64.dev` (`continuum-api/src/routes/qubes.ts`).
- [x] Naming → reverse-DNS dotted snake_case (`dev.q64.webmcp_client`); name =
      module path = URL segment, no transforms; `q64.*` reserved for stdlib.
      Specced across `qube.json5.md`/`.schema.json`, `modules.md`,
      `continuum-api.md`, `q64-cli.md`, `qube-cli.md`.
- [x] `qube login` / `publish` / `add` implemented (`qube/src/main.zig`) and
      tested live: publish packs+uploads; add resolves → downloads → SHA-256
      verifies → extracts to `~/.qube/cache/sha256/<ab>/<cd>/<digest>/` → edits
      the manifest's `dependencies`.
- [x] Test pair built: `dev.q64.hello_world` (published, live) + `dev.q64.hello_app`.

### The linking ladder (do in order)
0. [x] **DO FIRST.** `q64 emit` now **errors** on constructs it can't compile
       instead of silently embedding them — string interpolation whose value
       isn't a compile-time constant (`UnsupportedInterpolation` /
       `NotConstExpr`) and imports it can't resolve (`UnknownModule` /
       `NameNotFound` / `UnsupportedImport`). `q64/src/codegen/emit.zig`
       `Resolver` + `renderStringLit`; `cmdEmit` reports + exits non-zero.
1. [x] JSON5 manifest parsing in `qube run`/`web` (`qube/src/main.zig`
       `json5ToJson` strips `//`+`/* */` comments and trailing commas, then
       parses with `std.json` into a `Value`). Single-quoted strings /
       unquoted keys not yet handled (no manifest in the corpus uses them).
2. [x] `--module <name>=<dir>` flag in `q64` (`q64/src/main.zig` `cmdEmit`),
       repeatable. Reads each module's `src/lib.q` and hands codegen a
       `[]ModuleSource`. Spec: `q64-cli.md:71`.
3. [x] Import resolution in codegen (`q64/src/codegen/emit.zig` `Resolver`):
       resolves `import dev.q64.hello_world.{version}` via the `--module`
       map. Bare-dotted selective imports only for now; relative + stdlib
       imports error (`UnsupportedImport`).
4. [x] `qube run`/`web` pass `--module` per dependency (`resolveModuleSpecs`
       maps each `path` dependency → `<dep>/src` absolute). Local-path deps
       only; a registry/git dep is reported and rejected (wants the
       `qube.lock` + cache resolution below).
5. [x] Cross-module calls land **for real**: `env.out(version())` now emits
       `version` as a wasm `() -> (i64, i64)` function returning `(ptr, len)`
       (the v0 string-return ABI) and calls it at runtime — not folded.
       `q64/src/codegen/emit.zig` `ensureCallee` + `emitModule` (action plan
       + Multivalue feature + tuple local). Const-folding remains for
       interpolation (`"{version()}"`). Confirmed: the real form emits two
       functions, the folded form one. Interpolated string *concatenation*
       at runtime (a string builder over linear memory) is the next ABI step.
7. [x] **Memory64 / 64-bit ABI.** Per `spec/memory.md` (Wasm 3.0, 64-bit
       mode), codegen now emits a Memory64 linear memory with `i64`
       pointers; `env.out` is `(i64, i64) -> ()`. `emit.zig` enables the
       Memory64 feature + i64 consts/segment offsets; the wasmtime host
       (`runtime/wasmtime/`) enables `wasm_memory64` on the engine config
       and reads i64 args; `hello.wat` updated to `i64`/`(memory … i64 …)`.
       Verified: emitted memory section flags = `0x05` (has-max + 64-bit).
8. [x] **Scope arena + runtime string concatenation.** First *writable*
       region: a mutable `sp` bump-pointer global starting past the static
       data (`spec/memory.md` §"Region kinds", the implicit `scope` Arena).
       Interpolation containing a call (`"q64 v{version()} ok"`) is now
       built at run time — `emitFn` splits the literal into segments
       (`splitInterpolation`), `emitModule` lowers a `print_concat`:
       bump-alloc the total length, `memory.copy` each const run / call
       result into the buffer, then `env.out` it. Needs BulkMemory(+Opt)
       for `memory.copy`. Pure-constant interpolation still folds.
       Verified end-to-end: `scripts/link-roundtrip.sh` now asserts
       `q64 v0.1.0 ok` (a 3-segment runtime concat). v0 arena has no
       reclamation (single `_start` run, 1 page).
9. [x] **String parameters + argument passing.** A `str` parameter lowers
       to two i64 wasm params (ptr, len); callees are emitted as
       `(i64×2·params) -> (i64, i64)`. v0 bodies are passthrough
       (`fn id(s: str) -> str { s }` returns the parameter); `ensureCallee`
       detects the param-ref body, `emitFn` materializes string-literal
       arguments into the data segment and the `print_callee` call site
       passes them, with an arg-count check. Verified end-to-end:
       `link-roundtrip.sh` asserts `env.out(id("passed")) -> passed`.
10. [x] **Parameterized bodies that transform their arguments.** A callee
       body that interpolates its parameter (`fn shout(s: str) -> str {
       "{s}!" }`) is built in the scope arena and returned. Generalized the
       arena concat into `appendConcat` (used by both `_start` and callee
       bodies); `Segment` gained a `param` variant, `splitInterpolation`
       became parameter-aware, and the callee emits the concat + returns
       `(buf, len)`. `link-roundtrip.sh` asserts `shout("loud") -> loud!`.
11. [x] **Multi-argument functions + composed call arguments** (verified +
       regression-locked; these fell out of the param work). A callee may
       take several `str` params (`fn join(a, b) { "{a}-{b}" }` →
       `join("x","y")` → `x-y`), and a const-foldable call may be passed as
       an argument (`shout(version())` → `0.1.0!`, the inner call folds to
       the argument bytes). Covered by emit unit tests + `link-roundtrip.sh`.
       **Boundary / next:** genuinely *runtime* (non-const) arguments and
       nested non-const calls aren't supported — they need a runtime
       (ptr,len) passed at the call site, which has no consumer until there
       is a non-const string source (e.g. `let` bindings of call results,
       host inputs). After that: the `Stack` region kind (LIFO, freed on
       return) and multi-memory segregation (`spec/memory.md`).
12. [x] **Compile-time `let` / `var` bindings in `main`.** A binding names a
       const-foldable value (literal, const call, const interpolation);
       later statements reference it directly (`env.out(name)`) or in
       interpolation (`"Hello, {name}!"`), and bindings can reference
       earlier bindings. Lives in the resolver: a `bindings` table +
       `constEvalExpr` resolving a `.path` to a bound value; `emitFn`
       records each `let` and folds references. Verified end-to-end
       (`link-roundtrip.sh`: `let name/v` → `Hello, world! (q64 v0.1.0)`).
13. [x] **Runtime `let` bindings — the first genuine non-const values.** When
       a `let` initializer isn't const-foldable (`let g = shout("hi")`), the
       binding holds the call's `(ptr, len)` in two `_start` locals (binding
       locals occupy the front of the frame). References read those locals:
       `env.out(g)` (a `print_binding` action) and `"{g}"` (a `binding`
       concat segment), so a binding can be used many times from one
       evaluation. `_start`'s local layout became
       `[binding i64s][transient tuples][buf/off/len scratch]`; a `bind_call`
       action computes the value. Verified end-to-end (`link-roundtrip.sh`:
       `let g = shout("hi")` → `hi!` / `got: hi! and hi!`).
14. [x] **Runtime arguments.** A runtime binding can now be *passed* into a
       call: `ArgVal` became `constant | binding`, `extractCallArgs` detects
       a bare reference to a runtime binding and passes its locals
       (`local.get ptr/len`) rather than const-folding. This completes the
       value flow — `let g = shout("hi"); let w = wrap(g); env.out("{w}")`
       binds, passes, binds the result, and references it. Verified
       end-to-end (`link-roundtrip.sh`: `wrap(g)` → `[hi!]` / `nested:
       [hi!]`). **Boundary:** the argument must be a binding or a const — a
       *nested* non-const call (`wrap(shout("yo"))`) still errors; bind it
       first. **Remaining `spec/memory.md` work:** the `Stack` region kind
       (LIFO, freed on return) and multi-memory segregation.
6. [x] Codegen: string interpolation `"{expr}"` — `{expr}` is parsed (via
       `parse.parseExpression`), const-evaluated, and concatenated; `{{`/`}}`
       are literal braces. Runtime-valued interpolations error honestly.
15. [x] **Control flow — `if`/`else` in i64 functions.** An i64-returning
       function whose body is an `if`/`else` (or an else-if chain) lowers to a
       wasm `BinaryenIf` yielding i64; each branch's block contributes its
       tail value, recursing for nested ifs. Conditions lower via `emitCond`:
       the comparison operators `== != < <= > >=` become signed i64
       comparisons, and any other i64 expression is truthiness-tested
       (`x != 0`). A value `if` must end in an `else` (every path yields a
       value) or it errors (`UnsupportedCall`). New `emitFn` helpers
       `emitIntBody`/`emitIntBlock`/`emitIfInt`/`emitCond`. Composes with
       bindings, runtime args, and interpolation (e.g. `let m = max(10, 4);
       let c = clamp(m, 7); "max={m}, clamped={c}"`). Verified end-to-end
       (`link-roundtrip.sh`: `max`/`sign`/`abs`/`clamp` → `9 / -1 / 13 /
       max=10, clamped=7`) + emit unit tests. **Boundary:** conditions and
       branches are i64-only (no `bool`/`str` values yet); no loops; in-body
       `let` bindings inside a callee aren't supported (only the tail
       statement contributes the value).
16. [x] **In-function `let`/`var`, `var` reassignment, and `while` loops in
       i64 functions.** i64 callees can now express iterative algorithms.
       `emitIntBlock` walks every statement (not just the tail): in-body
       `let`/`var` declare wasm locals (`emitIntStmt` + a new `IntScope`
       mapping name → local index + mutability), `assign` reassigns a `var`
       (`emitAssignInt`: `= += -= *= /= %=`, signed; rejects `let`/params with
       `ImmutableAssign`), and `while cond { … }` lowers to a test-first
       `block`/`loop`/`br_if(eqz cond)` with unique labels (`emitWhileInt`,
       mirroring `__fmt_i64`'s loop). The i64 emitters thread `*IntScope` in
       place of the flat param-name list; `emitIntBody` returns the body plus
       the extra-local count so the call site declares the `varTypes`. The
       tail still yields the value (expr/`return`/`if`); a block ending in a
       statement with no value errors (`UnsupportedCall`). Verified end-to-end
       (`link-roundtrip.sh`: `sum_to(10)`/`fact(5)`/`poly(3)`/`sum_to(100)` →
       `55 / 120 / 12 / sum_to(100)=5050`) + emit unit tests (incl. the two
       immutable-assign rejections). **Boundary:** still i64-only; no `loop`/
       `for`/range iteration, no `break`/`continue`, no loops or in-body
       bindings in `main` (the `_start` body uses the resolver path), and no
       calls inside `emitIntExpr` (`fn g(n){ f(n)+1 }` stays `NotConstExpr`) —
       these are the next rung.
17. [x] **Calls inside i64 functions — composition + recursion.** `emitIntExpr`
       gained a `.call` arm: it lowers `f(args…)` to a `BinaryenCall` returning
       i64, with each argument lowered as an i64 expression. So an i64 function
       can call any i64 function — including itself (`fact`/`fib`/`gcd`) and
       mutually (`is_even`/`is_odd`) — and compose helpers (`hyp_sq` →
       `square`). A pre-emission pass (`registerCalls`/`…Block`/`…If`/`…Expr`
       in `emitFn`, before `emitModule`) walks each i64 callee body and
       `ensureCallee`s every call site, so transitively-reached functions are
       registered + emitted; index-based iteration + name dedup makes it a
       terminating fixpoint, and the captured `FnDecl` is a stable CST pointer.
       The registered callees ride on `IntScope.callees` so the `.call` arm
       resolves a target by name (validating it's an `int_fn` and that the arg
       count matches `n_params`). Self/forward/mutual references resolve by
       name at module finalization. Verified end-to-end (`link-roundtrip.sh`:
       `fact(6)`/`fib(10)`/`gcd(48,36)`/`hyp_sq(3,4)` → `720 / 55 / 12 / 25`) +
       emit unit tests (incl. arg-count and non-i64-callee rejections).
       **Boundary:** a call resolves only to a function in the symbol table —
       an imported name or a local function in the same file. Calling a
       dependency's *non-imported* / private helper still errors
       (`NameNotFound`); that wants the name-resolution pass. Also still no
       `loop`/`for`/range, no `break`/`continue`, and no loops or in-body
       bindings in `main`.
18. [x] **`break` / `continue` / early `return` / `loop` in i64 functions.**
       The i64 body emitters now lower the full control-flow set, so loops can
       exit early and iterate with skips. `IntScope` gained a loop-label stack
       (`loops` + `topLoop`); `emitWhileInt`/`emitLoopInt` push the (exit,
       re-enter) labels around the body. `emitIntStmt` gained arms for
       `break`→`br $exit`, `continue`→`br $reenter`, early `return`→
       `BinaryenReturn`, a statement-position `if` (`emitVoidIf`, `none`-typed,
       branches may break/continue/return), and `loop { … }` (`emitLoopInt`:
       `block $b { loop $l { <body>; br $l } }`). A `loop` as a function's
       value tail diverges — `emitIntBlock` emits it then an `unreachable` so
       the block still types i64 (it must exit via `return`). `break`/
       `continue` outside any loop error (`BreakOutsideLoop`); value-carrying
       `break x` is rejected for v0. Verified end-to-end (`link-roundtrip.sh`:
       `first_factor(15)`/`first_factor(49)`/`is_prime(13)`/`is_prime(9)`/
       `sum_odd(10)`/`count_to_sum(10)` → `3 / 7 / 1 / 0 / 25 /
       count_to_sum(10)=4`) + emit unit tests (incl. break/continue-outside-
       loop rejections). **Boundary:** still i64-only; no `for`/range iteration
       (range expressions don't parse yet — `0..n`), no value-`break`, and no
       loops or in-body control flow in `main` (the `_start` resolver path).

**Definition of done met.** `cd examples/link-demo/hello_app && qube run`
prints `0.1.0` by linking `dev.q64.hello_world` (a local-path dependency)
and calling its `version()`. Durable regression test:
`scripts/link-roundtrip.sh` (covers `q64 emit --module` *and* `qube run`) +
`examples/link-demo/`.

The long pole — a real (non-const-folded) cross-module call — is **done**
(step 5 above). `scripts/link-roundtrip.sh` now exercises the real call.
Next on the codegen path: callees with parameters (the AST shape is ready;
needs argument passing + a memory/stack convention) and runtime string
concatenation for interpolation.

### Deferred package bits (not compiler; pick up anytime)
- [ ] `qube.lock` — `add` doesn't write one; needed for ladder step 4.
- [ ] `add` dedup + `--offline` / `--frozen` / `--locked` flags.
- [ ] `qube publish` clean-release-build check (`qube-cli.md` publish step 4) — blocked on compiler.
- [ ] `qube remove` / `install` / `outdated` still stubs.

### Notes for the next agent
- Build with the **vendored** zig: `vendor/zig/zig build` (homebrew zig at
  `/opt/homebrew/bin/zig` has different `std.Io` APIs). The login command had
  stale `takeDelimiterExclusive`/`readAllAlloc` calls fixed this session to
  match the pinned zig — watch for the same drift elsewhere.
- Deploy the registry: `cd continuum-api && CLOUDFLARE_ACCOUNT_ID=<your-account-id> pnpm run deploy` (needs `wrangler login`).
- Registry auth is a pre-OAuth dev bypass at `POST /v1/auth/token`; credentials are set per-deploy via `BYPASS_EMAIL` + `BYPASS_PASSWORD` env vars (bypass returns 503 if either is unset). Route lives in `continuum-api/src/routes/auth.ts`; delete when OAuth lands.

## Q64 IR — two-tier backend-neutral IR (HIR/MIR) — ACTIVE

Honoring the decision that semantics must not depend on a backend's IR. We
lower to our own IR first: **HIR** (Semantic QIR) → **MIR** (Executable QIR) →
Binaryen/WASM, with a future `MIR → LLVM → native` backend an additive change.
Full design + phasing in the approved plan
(`/root/.claude/plans/question-the-important-design-purring-beacon.md`) and
[`q64/src/ir/README.md`](./q64/src/ir/README.md). Migrates incrementally behind
a per-construct router in `codegen/emit.zig` (legacy `AST → Binaryen` is the
fallback); `Q64_IR_STRICT=1` panics on fallback to track coverage. MIR control
flow is **structured** (wasm-shaped) with an explicit **CFG escape hatch**:
`mir.Func.body` is `Body = structured | cfg`, the `cfg` arm (`BasicBlock` +
`Terminator`) reserved for a future relooper/LLVM backend (WASM backend rejects
it with `CfgUnsupported`).

- [x] **P0 scaffold + P1 literals.** `q64/src/ir/` package: `hir.zig`/`mir.zig`
      (pure Zig, no Binaryen), `build_hir.zig` (AST→HIR), `lower.zig` (HIR→MIR),
      `print.zig` (dumps). Wired into `build.zig` (`ir_mod` + `ir_tests`).
      `emitFromSource` routes `fn main` of `env.out("<const string>")` through
      `AST→HIR→MIR→Binaryen` (`lowerToWasm`/`lowerInst`); everything else falls
      back to legacy. Verified: 169/169 unit tests (7 new IR tests),
      `link-roundtrip.sh` green, and `Q64_IR_STRICT=1` runs literals / panics on
      interpolation as designed. ARCHITECTURE.md updated (pipeline + `ir` stage).
- [x] **P2 i64 + control flow.** `build_hir` transcribes i64 functions (params,
      in-body `let`/`var` with index assignment, compound-assign desugaring) +
      the callee fixpoint (recursion reserves params before the body so arity
      checks pass); `lower` ports the `emitIntBlock` tail/control-flow logic
      (value vs void `if`, `while`→loop, diverging `loop`+`unreachable`) into
      structured MIR (`if_`/`while_`/`loop`/`br`/`br_cont`/`ret`); the backend
      `Lowerer` expands those with a label stack + emits multi-function modules,
      `__fmt_i64`, the arena `sp` global, and the pair scratch local. `lower`
      returns `Unsupported` for not-yet-handled shapes → router falls back.
      Verified with `Q64_IR_STRICT=1`: `fact`/`fib`/`gcd`/`sum_to`/`first_factor`/
      `sum_odd` → `720/55/12/5050/7/25` all through AST→HIR→MIR→Binaryen;
      170/170 unit tests + link-roundtrip.sh green.
- [x] **P3a compile-time strings.** `ir/consteval.zig` (ported from the legacy
      `Resolver`): folds const string interpolation, integer arithmetic, const
      `let` bindings, and const-bodied nullary calls — the last only in a `let`
      initializer (`fold_calls`), matching "direct `env.out(f())` is a real
      call." `build_hir` evaluates `main`'s `let`s into evaluator bindings and
      folds const `env.out` args to `host_out` (str_const) — reusing P1's data
      path, no MIR/backend changes. Verified via `Q64_IR_STRICT=1`:
      `"{(1+2)*3} {n+1} {1_000+24}"`→`9 43 1024` and `let name/v` + interpolation
      → `Hello, world! (q64 v0.1.0)` route through the IR; 172 tests + roundtrip
      green.
- **P3b runtime string ABI** (in progress). The `(ptr,len)` ABI in MIR
  (`ValueType.str` = a pair; backend realizes it as a two-i64 multivalue).
  - [x] **P3b-1 str-returning const functions + `env.out(str_call)`.** MIR gains
        `str_const_val` (→ `TupleMake`) and `host_out_str` (store pair, extract,
        env.out, newline); a str fn returns `pair_type`; the call-result type
        comes from the callee's `ret`. `build_hir` registers str functions
        (`registerStrFunc`, nullary, const-literal body) and routes a str-call
        `env.out` arg to `host_out_str` (`isStrCall`); `buildIntExpr` now rejects
        a str callee in an i64 context. Verified `Q64_IR_STRICT=1`: the link-demo
        `env.out(version())` → `0.1.0` through AST→HIR→MIR→Binaryen.
  - [x] **P3b-2** str params + passthrough (`id(s){s}`), str-literal/const-call
        args. MIR `str_param` (→ `TupleMake` of locals `2·idx`,`2·idx+1`); the
        backend expands a str param into two i64 wasm params and a str argument
        into two i64 operands (`strOperands`). `build_hir` registers all-str-param
        str functions; `buildStrArg` folds a const arg (`id(vshout())`) or passes
        a parameter through. Verified `Q64_IR_STRICT=1`: `id("passed")`→`passed`,
        `id(vshout())`→`0.1.0`.
  - [x] **P3b-3** concat / interpolation. MIR `str_concat` ([]piece); the backend
        `emitConcat` ports the legacy `appendConcat` (call pieces → tuple slots,
        sum lengths, bump `sp`, `memory.copy` each), yielding `(buf,len)`. Per-
        function scratch layout (`scanScratch` → tuple slots + buf/off/len) for
        both entry and callees. `build_hir.buildConcat` splits an interpolation
        into const-run / param / nullary-call pieces (folding const interps).
        Verified `Q64_IR_STRICT=1`: `"q64 v{version()} ok"`→`q64 v0.1.0 ok`,
        `shout("loud")`→`loud!`, `join("a","b")`→`a-b`, `shout(version())`→`0.1.0!`.
  - [x] **P3b-4** runtime str `let`/`var` bindings + runtime args. MIR `str_bind`
        (split a str value's (ptr,len) into two locals) + `str_binding` (read
        them); `emitConcat`/`strOperands` gained a `str_binding` piece/operand.
        `build_hir` tracks `main`'s runtime str bindings (`main_rt`) + their
        backing locals (`main_locals`), threaded as an `rt` scope through the str
        builders so `{g}`, `env.out(g)`, and `wrap(g)` resolve. Fixed: `lower`
        now carries the entry's `locals` into MIR. Verified `Q64_IR_STRICT=1`:
        `let g = shout("hi"); env.out(g); "{g} and {g}"; let w = wrap(g); "{w}"`
        → `hi!` / `got: hi! and hi!` / `nested: [hi!]`.
  - [ ] **P3b-5** i64 bindings + int interpolation in `main`.
  After P3b the whole suite + `link-roundtrip.sh` runs through the IR.
- [ ] **P4 delete legacy.** Once the router never falls through (verify with
      `Q64_IR_STRICT=1`), remove `emitFn`/`emitModule`'s AST walk, the
      `Action`/`Segment`/`ArgVal`/`RtBinding` model, and the `Resolver`.
- [ ] **P5 introspection + tail seams.** `q64 show hir|mir`; populate HIR
      visibility/effect slots for the component/WIT + QubePod bundle stages.
- [ ] **Later: native via LLVM.** A `codegen` sibling lowering `MIR → LLVM IR`,
      plus a native host ABI for the `env.*` capability faces (the one piece not
      inherited from the WASM component model).

## C bindings

Two distinct questions, both currently "planned, not active."

### Compiler → C (Binaryen for Wasm codegen)

Documented in [`q64/src/codegen/README.md`](./q64/src/codegen/README.md)
and [`q64/vendor/README.md`](./q64/vendor/README.md). Today: zero C
deps pulled in; `q64/zig-out/bin/q64` is pure Zig (lex / parse / diag
only). Plan:

- [ ] Vendor Binaryen (`q64/vendor/binaryen/`, currently empty). Use
      `build.zig.zon` if upstream publishes a tarball; otherwise git
      submodule per `vendor/README.md`.
- [ ] Update `q64/build.zig` to link the Binaryen C library (`addCSourceFiles`
      or `linkSystemLibrary` with the vendored headers).
- [ ] Stub `q64/src/codegen/emit.zig` that opens the C API and produces
      an empty Wasm module. Validates the cross-compile story and gives
      codegen its first checkpoint.
- [ ] Wire `q64 emit <file>` into `src/main.zig` so we can dump the
      empty module from a parsed `.q` file.

Estimated effort: ~1 day for the stub; the real codegen lands later
production-by-production.

### User code → C (FFI from q64 programs)

Not specced. The corpus has no `extern "C"`, no `@cImport`-like form,
no `wasm-c-abi` discussion. Everything external goes through capability
faces in `env.md` plus the runtime adapters in `runtime/<host>/`.

This is a deliberate consequence of "the platform is Wasm 3.0" but
worth being explicit about. Decision needed:

- [ ] Write `spec/ffi.md` that either:
  - **(a)** commits to "no language-level FFI; everything goes through
    Wasm imports declared by runtime adapters and surfaced as capability
    faces" — close the gap by stating the rule, and document how
    a third-party C library reaches q64 today (compile to Wasm separately,
    add a runtime adapter that imports its exports, wrap as a face), or
  - **(b)** specifies a language-level FFI surface — `extern fn` on top
    of the Wasm component model, with effect markers / capability
    integration so the disclosure story keeps working.
- [ ] Update `runtime/*/README.md` to point at whichever decision lands.
- [ ] Cross-link from `env.md` so a reader who asks "how do I call this
      C library" has a documented answer.

(a) is the smaller spec; (b) is the larger commitment. Recommendation
is (a) for v0, with (b) deferred to a future revision once the
component-model story stabilizes upstream.

## Host ABI for non-trivial faces — discussion phase

`env.out`'s `(ptr: i32, len: i32) -> ()` works for "bytes to stdout"
because the host knows the bytes are UTF-8 and that's it. Real faces
have structure — `env.audio` enumerates devices, reports
AudioWorklet status, hands off streaming buffers, takes callbacks
back into the module at audio-thread rate. None of that fits a raw
ptr+len convention.

We need to pick **one** "fixed form" for typed faces before more
stdlib code accretes. Options, ranked by how much new toolchain we
take on:

1. **Hand-specced per-face ABI in `spec/<face>.md`.** Memory layouts
   for records (`{id, name, channels, sample_rate}`), return-via-
   out-ptr conventions, error tag bytes, callback function-table
   slots. Host code (`runtime/wasmtime/`, `runtime/browser/`,
   `runtime/audio-host/`) implements decoders against the spec.
   Cheapest now; brittle as faces multiply.
2. **WIT / Component Model for non-trivial faces.** Keep `(ptr,len)`
   for `env.out`-class trivia; spec `Audio`, `Net`, `Fs` in WIT and
   lower through the component model. Standard-flavored, generated
   host bindings, but commits us to CM tooling and the runtime
   adapters grow a CM layer.
3. **Wasm GC reference types.** Pass typed `struct` / `array` refs
   across the import; no marshaling. q64 already targets Wasm 3.0,
   but Binaryen's GC support for generated modules isn't mature
   enough today.

JS-side: regardless of which path, the browser host (`runtime/browser/`)
needs a glue ESM that users drop into their site — `import { runQ64 }
from 'q64-browser-host'` style. The shape of that module depends on
which option above we pick; (1) means hand-written decoders per face,
(2) means generated bindings, (3) means very thin glue + Wasm GC
interop.

- [ ] Decide between (1) / (2) / (3). Probably (1) for v0 with a
      clear migration path to (2). Capture the decision in
      `spec/faces.md` and link from `spec/audio.md` when that lands.
- [ ] Spec the audio face wire format as the first concrete
      instance — drives the abstraction by example.
- [ ] Sketch the browser-host JS glue API (`runQ64`, capability
      injection, AudioWorklet bridge) so the debug page in
      [qube web] can render it.
- [ ] Cross-link from `env.md` and each face's spec.

## Other open items

This section grows as we go. Each item should have a checkbox so it's
visible at a glance whether it's been picked up.

- [x] Parser-emitted syntactic NAM diagnostics: `NAM003` (wildcard import),
      `NAM004` (selective+alias), `NAM009` (block `pub`), `NAM011` (dash in
      bare path). Conformance 6→10. The semantic NAM codes (`NAM001/002/005…`,
      need a name-resolution pass) and `LEX020/021`, `PAR040` remain.
- [x] Parser: items productions. `fn`, `import`, `struct`, `enum`, `type`,
      `const`, `face`, `fit` all parse now (shared `pub` prefix +
      `itemKeyword` dispatch). Struct record fields and enum variants are
      structured; field/variant *types*, generic-param internals, and
      face/fit method bodies are still raw token spans (pending the
      type-expression grammar). New item nodes aren't surfaced through
      `ast.Item` yet (only `FnDecl`), so codegen is unaffected. Real
      `dev.q64.webmcp_client` library files now parse with no diagnostics.
- [x] Parser: full expression precedence chain (binary/unary/try/postfix)
      from `grammar.md`. `parseBinExpr` (precedence climbing) over
      `parseUnary`→`parseTryExpr`→`parsePostfix`→`parsePrimary`; postfix
      call/index/field/method/tuple-field/`?.`; paren/tuple/array primaries.
      Dotted paths stay one greedy `PATH_EXPR` so `env.out(…)` keeps its
      `CALL_EXPR[PATH_EXPR, CALL_ARGS]` shape (codegen unchanged).
      **`PAR040` was attempted here but reverted**: telling a generic call
      (`PCM<f32>(0.0)`) from a chained comparison (`a < b > c`) needs name
      resolution — a pure-syntax heuristic false-positives on valid
      generics. PAR040 is therefore deferred to the name-resolution pass.
- [x] AST views: **complete** — every CST production the parser emits now
      has a typed view in `q64/src/parser/ast.zig`.
      • Items: `ast.Item` exposes `fn`/`struct`/`enum`/`type`/`const`/`face`/
        `fit` (visibility + name; struct `Field`s, enum `Variant`s, type
        `aliasedText`, const `value`).
      • Statements: `ast.Stmt` exposes `expr`/`let`/`return`/`assign`/`if`/
        `while`/`loop`/`for`/`match`/`break`/`continue`/`panic` (conditions,
        bodies, patterns, `MatchArm`s, assign target/value/op).
      • Expressions: `ast.Expr` exposes `bin`/`pipe`/`unary`/`try`/`call`/
        `index`/`field`/`method`/`tuple_field`/`question_dot`/`tuple`/`paren`/
        `array`/`path`/literals (operands, operators, args, elements).
      Codegen's exhaustive `Item`/`Stmt` switches gained `else` arms (it
      still lowers only the subset it understands).
- [x] **TypeExpr grammar (v0 floor).** Types are no longer raw spans:
      `parseType` (`parse.zig`) structures path (dotted name + raw
      `GenericArgs`), `ref`, slice/array, tuple, and optional, with a raw
      `TYPE_EXPR` fallback for fn/dyn/union. Wired into every type position
      (return type, params, fields, type/const/let). `ast.TypeExpr` exposes
      `path`/`ref`/`slice`/`array`/`tuple`/`optional`/`raw` with
      `PathType.name()` + `genericArgsText()`, element/inner/elements
      accessors, and `.text()`; `ReturnType`/`Param`/`Field`/`TypeDecl`
      gained `.type_()`. `.text()`/`typeText()` still work (`joinTokensAfter`
      now collects tokens recursively through the type node). Codegen is
      type-agnostic so it's unaffected; roundtrips green.
      **Deferred (parser-level):** structured generic args (`>>`-splitting),
      fn/dyn/union type structure, pattern destructuring internals,
      generic-param/effect/where internals, and the not-yet-parsed expr
      kinds (`record`/`range`/`lambda`/`spawn`/`channel`/`graph`).
- [x] **Compile-time integer arithmetic.** The resolver's `constEvalExpr`
      now folds integer expressions (`constEvalInt`): literals (decimal /
      `0x` / `0o` / `0b`, `_` separators), `+ - * / % & | ^ << >>`, unary
      `-`/`~`, parentheses, and bindings holding an integer. The decimal
      result renders into interpolation, so `env.out("{(1 + 2) * 3}")` →
      `9` and `let n = 6 * 7; "{n + 1}"` → `43`. Overflow / divide-by-zero
      aren't const-foldable (`NotConstExpr`). `link-roundtrip.sh` asserts
      `{(1+2)*3} {n+1} {1_000+24}` → `9 43 1024`.
- [x] **Runtime integer functions.** An `i64`-returning function whose body
      references a parameter (`fn double(n: i64) -> i64 { n + n }`) can't
      const-fold, so it's emitted for real: `ensureCallee` detects the i64
      return (via the structured `TypeExpr`), `emitIntExpr` lowers the body
      to wasm i64 arithmetic, the callee is `(i64×params) -> i64`, and the
      result is formatted by `__fmt_i64` — a wasm routine (a digit loop +
      sign handling) that writes decimal into the scope arena and returns
      `(ptr, len)`. `env.out(double(21))` → `42`, all at runtime. Verified
      end-to-end across 0 / negatives / multi-digit / multi-param;
      `link-roundtrip.sh` asserts `double(21)`/`add(1000000,234567)`/`neg(7)`
      → `42` / `1234567` / `-7`.
- [x] **Runtime i64 bindings + chaining.** `RtBinding` is now a str/int
      union: a `let x = double(21)` stores the i64 result in a single
      `_start` local (`bind_int_call`), `env.out(x)` formats it via
      `__fmt_i64` (`print_int_binding`), and an i64 binding can be passed as
      an argument to another i64 function (`ArgVal.int_local`), so
      `let a = double(21); env.out(add(a, 8))` → `50` and calls chain
      (`add(a, c)`). Binding locals are assigned by a running counter (str
      takes two, int one). Type mismatches (str arg to an i64 param or vice
      versa) are rejected. `link-roundtrip.sh` asserts the binding/chaining
      path → `50`. **Deferred:** `var` reassignment of an i64.
- [x] **i64 bindings interpolate into strings.** A new `int_binding` segment
      (a binding local formatted via `__fmt_i64`) is handled in the concat
      builder exactly like a `call` segment — it claims a tuple slot, the
      formatter runs once into the arena, and its `(ptr, len)` feeds both the
      length sum and the `memory.copy`. So `"a = {a}"` → `a = 42` and a single
      concat can mix a str binding and an i64 binding (`"{g} a is {a}"` →
      `hi! a is 42`). `link-roundtrip.sh` asserts `"{g}: a={a}, b={b}"` →
      `hi!: a=42, b=50`. **Deferred:** interpolating an i64 *call* result
      (`"{add(a, b)}"`) — the call path still extracts string args, so an i64
      call in interpolation is `UnsupportedCall`.
- [x] AST views (statements): `ast.Stmt` now surfaces `let`/`var`
      (`LetStmt`: `isVar`/`pattern`/`initializer`) and `return`
      (`ReturnStmt.value`) alongside `expr_stmt`, plus a `Pattern` view
      (`bindingName`), structured `ReturnType.text()`, and
      `Params.isEmpty()`. Codegen can now walk a binding-and-returning
      body; a `return`-bodied const fn (`fn version() -> str { return
      "0.1.0" }`) folds via `constEvalFn`. This is the prerequisite the
      "long pole" above was waiting on.
- [x] AST views (params): `parseParams` (`parse.zig`) now emits structured
      `PARAM` nodes (`ParamMode? IDENT ":" TypeExpr`); `ast.Params.iter()`
      yields `Param` views with `mode()` / `name()` / `typeText()`. Inner
      generic commas (`Map<K, V>`) don't split a param. Type stays a raw
      span (shared `joinTokensAfter` helper with `ReturnType.text`) until
      the type-expression grammar lands. Real (non-const-folded) callee
      emission now consumes this shape (ladder step 5). Cheap AST follow-ups
      when codegen demands them: surface the already-parsed
      `BIN_EXPR`/`UNARY_EXPR` in `ast.Expr` and the control-flow statements
      in `ast.Stmt` (just `cast` arms).
- [x] Parser: statement productions inside `Block`. `let`/`var`,
      `return`/`break`/`continue`, `panic`, `if`/`else` (+ `if let`),
      `while`, `loop`, `for`, `match` (+ arms), and assignment vs
      expression statements all structure now (`parseStmt` dispatch).
      Only `EXPR_STMT` is surfaced to `ast.Stmt`, so codegen is
      unaffected. Still raw spans: let-bindings, for/match patterns,
      and types (pending the pattern grammar). Not yet structured:
      `scope`/`select`/`region`/`with_capabilities`/item-`const` (fall
      to the lossless expr/assign fallback).
- [x] Runtime: wasmtime host that runs `hello.wat` and prints
      "Hello, q64.\n" via the `env.out` import
      (runtime/wasmtime/src/main.zig). v0 byte-level golden for
      codegen.
- [x] Codegen: vendor Binaryen + `q64/src/codegen/emit.zig` with
      `emitHelloWasm()` that builds the hello module via the
      Binaryen C API. End-to-end roundtrip via
      `scripts/hello-roundtrip.sh`.
- [x] Codegen: graduate `emit.zig` from a hardcoded hello fixture
      to walking an `ast.FnDecl`. `emit.emitFromSource` parses a
      source file, walks `fn main`'s body, and emits a wasm module
      with N `env.out("…")` calls laid out in linear memory.
      `examples/hello/hello.q` + `scripts/hello-roundtrip.sh`
      exercise the full parse → AST → codegen → runtime chain.
- [x] Parser: pattern grammar (v0 floor). `parsePattern` covers wild /
      literal / ident / tuple / tuple-struct / record-struct / enum-variant,
      wired into `match` arms, `let`/`var`, `for` heads, and `if let`.
      Guards / or-patterns / ranges / deep destructuring still deferred
      (see "Pattern grammar completion" below). The real
      `dev.q64.webmcp_client` example app (match on strings + variants,
      `for`, raw strings, interpolation) now parses with no diagnostics.
- [x] Parser: lexer raw strings `r"…"` / `r#"…"#` (STR_RAW).
- [ ] Parser: record/struct **expression** literals (`Point { x: 1 }`,
      `DemoTools {}`) in expression position. Deferred for the
      struct-literal-vs-block ambiguity (Rust-style); today they degrade to
      lossless one-token recovery. Needs the disambiguation rule (likely:
      no bare record literal in `if`/`while`/`match` scrutinee position).
- [x] `spec/annotations.md` — categorize `@`-forms (markers / derive /
      property wrappers). Smallest scope, highest cross-reference value.
- [x] `spec/units.md` — drain the unit-suffix table out of `types.md`
      into a real lattice spec.
- [x] `spec/test-framework.md` — `@test`, fixtures, the `Arbitrary` face
      surface. `env.md` and `spec/tests/` both use `@test` but it has no
      spec home.
- [ ] Pattern grammar completion — close the `(* open *)` markers in
      `grammar.md` §Patterns (guards, or-patterns, deep destructuring,
      range patterns, exhaustiveness).
- [ ] `docs/history/` cleanup — once `units.md`, `kinds.md`,
      `annotations.md`, `strings.md` land, the historical sources for
      them can be archived or deleted. Per MIGRATION.md's own plan.

## Dual address space (wasm32 / wasm64) — NEW, SPEC LANDED

The `/wasm` probe on qubepods proved the floor: **Apple WebKit (Safari +
every iPad/iOS browser) has no Memory64 as of 2026.** The POC only "passed"
because it served a 32-bit Rust-built wasm — real `q64` output is 64-bit and
would not have run on iPad. So the address space is now an **explicit
per-build choice with no default** (decision recorded with the spec edits):
`wasm32` is the universal/WebKit baseline, `wasm64` adds Memory64 for capable
hosts. Specs updated: [`spec/memory.md`](./spec/memory.md) §"The platform" +
§"Address-space negotiation", [`spec/qube.json5.md`](./spec/qube.json5.md)
§Targets (`addressSpace` required), [`spec/q64-cli.md`](./spec/q64-cli.md) &
[`spec/qube-cli.md`](./spec/qube-cli.md) (`--addr`, per-`<addr>` output),
[`ARCHITECTURE.md`](./ARCHITECTURE.md), [`spec/continuum-api.md`](./spec/continuum-api.md).

Implementation (not started — large, touches the whole CLI + backend):

- [ ] **Backend: parameterize the address space.** `codegen/` currently bakes
      Memory64 + the arena bump global as the Binaryen realization. Make
      pointer width, `memory`/`table` declarations, and the allocator codegen
      switch on `wasm32` vs `wasm64`. This is the bulk of the work.
- [ ] **`q64` CLI: `--addr <wasm32|wasm64>`**, required; diagnostic when
      neither `--addr` nor a target-resolved `addressSpace` is given (new
      diagnostic code for "no address space selected").
- [ ] **`qube` CLI (build):** `addressSpace` required per target; build invokes
      `q64` once per address space; outputs under `target/<profile>/<addr>/`;
      `--addr` override; flag wasm64 builds as not-runnable-on-WebKit.
- [x] **`qube pod` CLI (deploy manifest):** `qube pod new`/`init` take
      `--addr <wasm32|wasm64>[,…]` and emit a `component.variants` map (per-addr
      paths derived from `--wasm`); legacy single-`wasm` is unchanged when
      `--addr` is omitted. `qube pod deploy` packs **every** declared variant
      into the bundle zip. Mirrors qubepods' `component.variants` schema; the
      generated manifest round-trips through `@qubepods/qubepod-schema`.
      (`qube/src/main.zig`, tests in `qube-test/tests/pod.test.ts`.)
- [ ] **Multi-memory layout under wasm32** — confirm the `mem.*` segregation
      (stack/arena/heap/shared/large/rodata) holds with `i32` addressing and
      the 4 GiB-per-memory cap.
- [ ] **Runtime/glue:** `runtime/browser/host.js` (and any wasmtime/wasmer
      host) probes Memory64 (`WebAssembly.validate` of a tiny `(memory i64 …)`
      module) and requests/loads the matching build; `wasm32` is the fallback.
- [ ] **`q64 show memories`** reports the address space it emitted.
- [ ] **Continuum (optional, future):** additive prebuilt-artifact endpoint
      `/v1/qubes/{name}/{version}/artifact?addr=…` if the source registry
      should ever serve compiled variants (see continuum-api.md note).

## Conventions

- Tick `[x]` when done. Strike through and leave the line until the
  next sweep so we have a trail.
- Keep items terse — link to the spec / file / commit rather than
  re-explaining context here.
- New items append to "Other open items" by default; pull out into a
  named section when more than a few related items accumulate (as
  C bindings has).
