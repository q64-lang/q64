# todo

Active work tracker. Things to do, things to decide, kept short and
ticked off as they land. Long-form design questions are tracked separately; this file is
for items the next session should be able to pick up and act on.

## Roadmap — sequenced phases (the map over the sections below)

A dependency-ordered view of the backlog. The detailed, line-level items
live in the topic sections further down; this is the *order* to do them in
and what gates what. Each phase links the section(s) that hold the work.

**Phase 0 — front-end + core codegen — DONE.** Lexer, structured parser
(items/exprs/stmts), the sema check pass, the **diagnostic ladder at full
conformance** (53/53), the HIR/MIR two-tier IR, cross-module linking,
wasm32/wasm64 dual address space, component emission v0, the `qube` CLI +
Continuum registry (live), and the QView reactive-state architecture POC
(iPad-verified). This is the "you can lint + run real q64" milestone.

**Phase 1 — Codegen & language breadth — IN PROGRESS, *no gate* (do in
parallel).** Grow how much of the language actually executes. None of this
needs the platform audit, so it's the highest-leverage near-term work.
Landed breadth (Vec HOFs + chaining, closures incl. runtime alias-capture,
ranges, Vec params, floats + native float builtins, `q64.math`
transcendentals, operator fits, Simd/Tensor first slices) lives in git; what
remains:
  - Generics beyond v0 monomorphization (§"B5 — generics beyond the first rung").
  - Numeric tower remainder: receiver-expression / record-field float
    receivers (§"Numeric tower").
  - Strings/lists beyond the floor + `str`/list **component exports**
    (§"Component emission").
  - Vec HOF boundaries: main-only, i64 elements, expr-body lambdas;
    chaining *after* a `.reduce` isn't a vec source; `Vec.new()` as an
    initializer (`Vec.from` only); local `Vec.new()`/`for` inside callees;
    array `for` in callees; ranges as general values (`let r = 0..n`).
  - Closure boundaries: capture *mutation* / write-back (TYP352-adjacent —
    the TYP352 check itself is also pending), non-scalar (record/str)
    captures, block-body lambdas, multiple fn-typed params, shared complex
    args (double-eval), str/record/closure-returning HOFs. Real
    `.map`/iterator HOFs build on this.
  - Units & dimensional arithmetic (`spec/units.md`; lexed, not evaluated).
    SI base dimensions land WITH this rung (`spec/units.md` §"v1 extension").
  - Pattern-grammar completion (§"Other open items" — close the `(* open *)` markers).
  - Memory reclamation — Stack discipline on the implicit arena (§"Memory reclamation").
  - **Structured parsing of the currently-raw block constructs**
    (`graph`/`scope`/`region`/`actor` bodies, leading annotations) — lets the
    token-scan diagnostics (STR/CONC/REG/EFF) become precise AST-level checks,
    and is a prerequisite for clean concurrency/stream *lowering* later.
  - `screen`/`draw` → `main` **lowering** + the browser-host glue wiring
    (§"QView…" — parse/AST done; lowering + `runtime/web` reading the i32
    `env.out` args remain).

**Phase 2 — Platform feature audit — THE GATE — DECISION RECORDED
(2026-06-14).** §"Wasm 3.0 feature audit". Matrix recorded in
`spec/memory.md` §"Concurrency platform audit": **stack-switching ships on
no host q64 targets** (wasmtime 45 has no C-API toggle; no browser stable);
tail-call/EH/GC are broadly available; threads need COOP/COEP. **v0
concurrency floor = single-threaded cooperative scheduler** (suspend only at
statically-known points, selective CPS lowering — not asyncify); threads +
stack-switching are capable-host upgrades behind the same scheduler. This
unblocks Phase 3. Remaining: the live `WebAssembly.validate` browser-probe
harness (confirm the WebKit/iPad column empirically) + maintainer sign-off on the
floor. Everything in Phase 3+ now has its target.

**Phase 3 — Concurrency runtime — gated on Phase 2 — STARTED.** Implement
the chosen floor: the scheduler, `spawn` + structured `scope` execution,
`channel` send/recv with the policies already diagnosed (Backpressure/
LatestValue/RingBuffer/Unbounded), and `actor` `tell`/`ask` dispatch. Then
the runtime effect checks the front end can't do statically (EFF110 assert/
operation violations, `@cancel` propagation). Specs: `concurrency.md`,
`concurrency-model.md`.
  - [ ] **Futures ladder (component-model async ABI, Bytecode Alliance spec).**
        The plan, in dependency order — each rung is spec-conformant on its own:
        - **Slice A — blocking waits, no CPS (IN PROGRESS).** The async ABI
          lets a *synchronously-lowered* caller of an async operation block
          (the host parks the task), so blocking faces need no language
          change. First face: `env.time.sleep_ns(ns)` — void, blocking —
          three lowerings like the other clock faces: local `env.sleep_ns`;
          preview1 `poll_oneoff` with one monotonic-clock subscription (the
          adapter lifts it to `wasi:io/poll`); component-mode
          `monotonic-clock.subscribe-duration` → `pollable.block` →
          `[resource-drop]pollable` (the minimal 0.2 blocking chain — three
          imports, contained in one emit arm, replaced wholesale by the P3
          async lower when Slice B lands). Spec rows in env.md; the async
          `sleep -> future<()>` form stays reserved for Slice B.
        - **Slice B — the CPS transform (the futures milestone proper).**
          Selective CPS at statically-known suspend points per the Phase 2
          decision (NOT asyncify); q64 exports lift `async` with the callback
          re-entry protocol + `task.return`; `sleep`/`await` become real
          suspension under the one cooperative scheduler. Runner: `wasmtime
          -S p3` (already the vendored runner).
          - _(protocol reference below, kept for the codegen's provenance)_
            **PROTOCOL PINNED (`test/async-export-reference/`).**
            Two hand-authored cores round-trip the Component Model async
            ABI under `wasmtime -W component-model-async -S p3`: a YIELD
            core proving lift/callback/task.return with zero imports, and
            the real one — `nap(ns)` starts `wait-for` as an async-lowered
            SUBTASK, joins a waitable-set, returns `WAIT(set)`; the callback
            fires on completion and `task.return`s the measured span
            (250ms → 251.7ms measured, host thread never blocked). Verified
            findings in the fixture README: legacy manglings only (standard
            cm32p2 has no async yet), `(subtask<<4)|state` packing with
            RETURNED=2, callback codes EXIT=0/YIELD=1/WAIT=2|set<<4, and
            wasmtime's p3 WASI is rc-versioned
            (`wasi:clocks@0.3.0-rc-2026-03-15`, `instant`→`mark`).
            Remaining codegen work (the mapping table is in the README):
            spill scheduler state (pc/deadlines/task locals) from function
            locals to globals or a memory frame so `main` is re-entrant,
            emit the legacy-mangled async imports/exports, and route the
            idle path to `wait-for`+WAIT instead of the blocking sleep.
        - **Slice C — `future<T>`/`stream<T>` as q64 values.** Maps the
          `Signal`/`Event`/`Stream` family (streams.md) onto the ABI's
          `{future,stream}.{new,read,write,cancel,close}` built-ins;
          clocks' `subscribe-*` and async `wasi:io@0.3` stdout ride this.

**Phase 4 — Streams / dataflow runtime — builds on Phase 3 — STARTED.** The
graph scheduler (stages as tasks), the `|>` pipe runtime, and
Signal/Event/Stream sampling semantics. The STR0xx diagnostics already guard
the front end; this makes graphs *run*. Spec: `streams.md`.

**Phase 5 — Reactivity productionization — builds on the QView POC +
Phase 3/4.** `@state(scope)` as first-class syntax + AST partitioning, the
typed twin `face`/RPC API beyond `inc`, MSDF text, and the full retained
`Renderer` face. Specs: `reactivity.md`, `agent-ui.md`.

**Phase 6 — WIT as the first-class contract layer — NEAR-TERM, *no gate*
(do before the SDK).** Promote WIT from an emit-only *view* of a qube to the
**authored-where-needed, stored, and consumed** contract that makes the
Continuum a polyglot component registry. WIT is the Component Model's standard
IDL, the key to cross-language qubes, and must be first-class in the library
manifest (`qube.json5`), the Continuum, the `qube`/`q64` CLIs, and the
qubepods host. Detailed rungs in §"WIT — first-class contract layer". The
foundational rungs (emit `.wit` + embed the component-type, manifest world,
Continuum storage/serve, CLI commands) extend already-live systems and need
no gate; **WIT ingestion** (binding imports to foreign `.wit`) is the larger
follow-on that unlocks true any-language interop. Sequence this **before** the
SDK — the SDK generates bindings *against* WIT, so the contract layer must
exist first.

**Cross-cutting / later (independent of the critical path).** RPC + `@wire`
(`rpc.md`); the full memory model — `Managed`/WasmGC heap, named regions,
`transfer` runtime (`memory.md`); C bindings / vendoring Binaryen
(§"C bindings"); the host ABI for non-trivial faces (§"Host ABI…"); `spec/
ffi.md` (unwritten); and the native **LLVM** backend (explicitly "Later").

**Critical path:** Phase 2 → 3 → 4, with 5 depending on 3/4. Phase 1, Phase 6
(WIT contract layer), and the cross-cutting bucket run in parallel and need no
gate. The single hard ordering constraint in the whole plan is
**audit-before-scheduler**; the single hard *product* constraint is
**WIT-before-SDK** (Phase 6 lands the contract the SDK generates against).

## Language-analysis follow-ups (2026-07) — NEW

Source: [`docs/language-analysis-2026-07.md`](./docs/language-analysis-2026-07.md)
— the assessment against the Julia/Mojo bar plus the domain plan (AI, robotics,
world models & digital twins, crypto, quantum, drug research). The items below
are the actionable deltas **not already tracked elsewhere in this file** — the
analysis's Tier-0 core (semantic pass, effect-assert enforcement, const
generics, memory reclamation, `spec/ffi.md`) is the existing §"Semantic pass…"
ladder, §"C bindings", and the roadmap phases, deliberately not duplicated here.

- [ ] **`q64.math` follow-ons:** generic `Complex<T>` (waits on generic
      structs). The item's core is complete — transcendentals, Complex,
      RNG (`env.random.u64`), loadable stdlib qubes, imported structs all
      landed (trail in git). (Analysis §3, item 8.)
- [ ] **Host-inference capability face** (`env.ai.infer`, `@inference`):
      WebNN (browser) / ONNX-runtime-or-GGML (native) behind one face, making
      `stdlib/ai`'s `Model<InVocab, OutVocab>` surface executable and feeding
      token streams into `Stream<Token<V>, R>` — the voice-agent flagship
      becomes buildable end-to-end. (Analysis §3, item 12.)

## Compiler + linking

The registry, the package up/download loop, and the whole linking ladder
are **done and live** (definition of done met: `examples/link-demo/hello_app`
prints `0.1.0` by calling `dev.q64.hello_world.version()` — a real,
non-const-folded cross-module call). Durable regression test:

```
./scripts/link-roundtrip.sh           # → PASS: 0.1.0
```

### Deferred package bits (not compiler; pick up anytime)
- [ ] `--frozen` / `--locked` flags; `add` dedup.
- [ ] `qube publish` clean-release-build check (`qube-cli.md` publish step 4) — blocked on compiler.
- [ ] `qube remove` / `outdated` still stubs.
- [ ] **`qube deploy` rejects static-asset qubes.** A qube with
      `static: { dir: "web" }` and no component (the `qubits`
      `qube_rocks`/`blackbird` shape) fails with `manifest has no
      component.wasm, component.module, or component.variants` — but the
      qubepods server already accepts a component-less bundle (the component is
      **optional** server-side; a manifest + asset tree is a valid deploy). So
      today static qubes must be shipped by hand-rolling the
      `POST <api>/api/deploy` multipart (verified — see `qubeworlds/qubekit`
      `apps/editor/deploy.sh`, live at `qubekit-editor.qubepod.app`). Fix: when
      there's no `component.*`, pack `qubepod.jsonc` + `assets.directory` only.
      Also update `spec/qube-cli.md` §`qube deploy` — it currently says the
      bundle is "the manifest, every component wasm, and the asset tree", which
      reads as component-required; spec the static-only case explicitly (spec is
      the source of truth, so it should define it).

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

P1–P3b are done: the entire `link-roundtrip.sh` corpus emits with
`Q64_IR_STRICT=1` and zero fallbacks. Remaining:

- **P4 delete legacy** (in progress).
- **P5 introspection + tail seams.**

## Component emission — `q64 emit --component` — ACTIVE

Wiring the WIT lift into a build artifact: a real WebAssembly **component**
wrapping the core module (spec/modules.md §"The qube as a component",
spec/q64-cli.md `--component`).

- [ ] **String / list exports.** Lift `str`-returning / `str`-param exports via
      the canonical ABI string representation (memory + realloc canon options);
      today they're skipped from the component surface.

- [ ] **Later: native via LLVM.** A `codegen` sibling lowering `MIR → LLVM IR`,
      plus a native host ABI for the `env.*` capability faces (the one piece not
      inherited from the WASM component model).
      **Decision recorded (2026-06): direct `MIR → LLVM IR`, no MLIR layer.**
      HIR→MIR already is the multi-level lowering MLIR would provide; the
      last hop is the *easy* direction (structured MIR → basic blocks is the
      same label-stack walk the Binaryen `Lowerer` does — no relooper; the
      `mir.Body.cfg` escape hatch isn't even needed for it), and MLIR's cost
      (a huge C++ dep on a pure-Zig compiler, C API hostile from Zig, a third
      IR) buys nothing at one CPU target. First rung when this activates:
      emit **textual `.ll`** (zero link deps — data image as a global byte
      array, `sp` global, structured-walk block emission, faces as `declare`d
      externals; system `clang`/`llc` consume it), upgrade to the LLVM C API
      later if warranted. The genuinely hard part is the native `env.*` host
      ABI shim, not the lowering. Pin down the value-add vs `wasmtime
      compile` (Cranelift AOT already runs the components natively) before
      building. Revisit MLIR only if Q64 grows multi-target (GPU) or its own
      mid-level optimization passes — and then as HIR/MIR *as dialects*, not
      a layer on top.

## WIT — first-class contract layer

The Component Model's IDL is **WIT**, and it's the contract that lets qubes
written in any language interoperate, the unit the Continuum should store and
serve, and the thing the `qube`/`q64` CLIs and the qubepods host must treat as
first-class. Today WIT is **emit-only** — `q64 show world` *synthesizes* a
world from a qube's surface (see §"Component emission" and `spec/modules.md`
§"The qube as a component"), and we never read foreign WIT. This section makes
WIT a real artifact: **emitted to disk, embedded in the component, declared in
the library manifest, stored/served by the Continuum, surfaced in the CLIs,
and — the big one — consumed.**

**Design rule (don't regress the existing decision).** A qube's *own* world
stays **synthesized, not authored** — q64's type + effect system is the single
source of truth, no hand-written `.wit` duplicating the source (`spec/modules.md`
§"The world is also the RPC contract"). What's new is the **consume**
direction: binding a qube's *imports* to an external, authored/foreign `.wit`
(a Rust/JS/Go component, or a shared interface package). Faces are **not**
widened to cover WIT `resource`s — foreign resources get an opaque handle type
*outside* the face system (see §"Host ABI for non-trivial faces" and the gap
notes below).

### Rung order

Rungs 1–4 (emit `.wit` + embed the component-type, manifest world,
Continuum storage/serve, the `q64 wit`/`qube wit` CLI verbs) are done —
trail in git. Remaining:

- [~] **5. WIT ingestion — consume foreign `.wit` (the big one).** Foundation
      landed end-to-end for the **scalar path** (trail in git): WIT parser +
      WIT→q64 type map + `q64 wit import` preview; component-level import
      declaration (`--wit-import`, manifest `wit.imports`); named-interface
      export (`--export-interface`, manifest `wit.interface`); q64↔q64
      link-at-build via `qube wac`; and source-level foreign *calls*
      (`<iface>.<fn>(args)` → `foreign_call` HIR/MIR → a real core import) —
      all verified in `scripts/wac-roundtrip.sh` (`compute(5) == 105` through
      a linked provider). Type gaps surface honestly (WIT020 `flags` / WIT021
      `char` / WIT022 anonymous tuples; foreign `resource` = opaque handle).
      **Remaining slice:** rich-type (non-scalar) foreign calls — they share
      the canonical-ABI memory glue still outstanding on the export side
      (§"Component emission" str/list exports).
- [ ] **6. Host-side composition (qubepods).** Tracked in `qubepods/TODO.md`
      §"WIT in the host" — the host validates a deployed component against its
      declared world and composes heterogeneous components over shared WIT.

### Known type-system gaps to close as ingestion lands

WIT primitives q64 has no representation for yet — surface honestly, don't
silently coerce: **`flags`** (no flags type, `spec/types.md`), **`char`** (no
Unicode-scalar type), and **anonymous `tuple<…>`** in *foreign* signatures
(q64 tuples are nominal, `spec/types.md` §"Tuple structs"). Each is additive.
Resources, own/borrow, and type-only interfaces are handled by the
opaque-handle approach in rung 5, **not** by widening faces.

## Continuum — OCI compliance (make the registry an OCI registry)

**Goal:** make the Continuum speak the **OCI Distribution Spec** so qubes (and
emitted components) are pushable/pullable with the whole existing OCI ecosystem —
`wkg` (`wasm-pkg-tools`), `oras`, `docker`/`crane`, every cloud registry's auth +
mirroring + CDN. Additive: the JSON API (`spec/continuum-api.md`) and the
`qube publish`/`add` UX stay the **opinionated front door**; OCI is a **second
protocol surface over the same content-addressed R2 store**, not a rewrite.

**Why.** The Bytecode Alliance retired the bespoke **Warg** protocol and moved
component distribution to **OCI** (the `bytecodealliance/wasm-pkg-tools`/`wkg`
line). A WIT-component world — incl. `qubeworlds:engine/scene` if the game engine
becomes an imported library — wants ecosystem-standard distribution. The
Continuum is *already* a content-addressed artifact store (canonical SHA-256 of
the `.zip` over R2 + D1 metadata), which is exactly OCI's model — so this is a
protocol facade, not new storage.

**The mapping (we already have the pieces):**
- qube name `dev.q64.math` + version → OCI **repository:tag** (`dev.q64.math:0.1.0`).
- canonical archive **SHA-256** → OCI blob **digest** (`sha256:<hex>`) — our
  R2 keys are already digest-addressed, so blobs map 1:1.
- An **OCI manifest** (`application/vnd.oci.image.manifest.v1+json`,
  `artifactType: application/vnd.q64.qube.v1+json`) referencing: a **config**
  blob = the `qube.json5` manifest JSON; **layer** blobs = the `.zip` archive
  (and/or the `.component.wasm` with `application/wasm`) + the synthesized `.wit`
  world. The `.wit` we already store/serve (WIT rung 3) becomes a typed layer.

**Rungs (do in order; all additive, no gate):**
- [~] **1. `GET /v2/` version check** + OCI **Bearer auth** flow
      (`WWW-Authenticate` → token), reusing the current auth backend
      (`continuum-api/src/routes/auth.ts`). **`GET /v2/` done** (200 anonymous +
      `Docker-Distribution-API-Version`); the Bearer/token flow lands with the
      write path (public pull needs no auth).
- [~] **2. Blob endpoints** — `HEAD/GET /v2/<name>/blobs/<digest>` (serve from
      R2 by digest; we already verify SHA-256) and the upload flow
      `POST .../blobs/uploads/` → `PUT` (monolithic first; chunked later).
      **Read half done** (GET/HEAD blobs: config/wit from `blobs/sha256/<h>`,
      `.zip` in place from `archives/<h>`); upload returns `405 UNSUPPORTED`.
- [~] **3. Manifest endpoints** — `PUT/GET/HEAD /v2/<name>/manifests/<ref>`
      (ref = tag or digest). Synthesize the OCI manifest from existing version
      metadata on read; on write, record it alongside the D1 version row.
      **Read half done** (synthesized on read, byte-stable canonical JSON →
      deterministic digest; derived blobs materialized lazily); `PUT` is `405`.
- [ ] **6. Interop check** — `wkg`/`oras pull dev.q64.math:0.1.0` round-trips a
      published qube; `oras push` of a component is consumable by `qube add`.
      (Pull path is unit + route tested in `continuum-api/test/oci*.test.ts`;
      live `oras pull` against a deployed worker is the remaining check.)
- [ ] **7. Docker Registry v2 Bearer-token protocol** — the
      `WWW-Authenticate: Bearer realm=…,service=…,scope=…` → token-endpoint
      (`GET /v2/token`) → `Authorization: Bearer <token>` handshake the OCI
      clients (`oras`, `docker`, `wkg`) perform, exchanging a `qube_pat_` PAT
      (HTTP Basic) for a short-lived registry token, reusing the existing auth
      backend (`routes/auth.ts` + `lib/tokens.ts`). **Gates the write/push path**
      (rung 2 upload + rung 3 `PUT` manifest) and any future private repos.
      **NOT needed for download:** public **pull** stays anonymous (no token,
      `GET /v2/` already answers 200) — so this is push-auth only, not a gate on
      the read surface that's already shipped.

Implementation: `continuum-api/src/routes/oci.ts` (mounted at `/v2`). Read path
(rungs 1,3,4 + the GET/HEAD half of 2) + rung 5 are done; the write path (the
rest of 2 + `PUT` manifest in 3) is the next increment, gated on the OCI Bearer
auth handshake (rung 7). Public pull is anonymous, so the read surface ships
without it.

**Coexistence:** both surfaces read/write the **same R2 blobs by digest** and the
**same D1 metadata** — publishing once is visible to both `qube add` and `wkg`.
Keep `qubes.q64.dev` (JSON API) and add the `/v2/` OCI routes on the same
`continuum-api` worker (or a sibling route). **Interop escape hatch, not a
migration** — the Continuum stays the primary, opinionated registry.

## `q64 show` — full introspection surface (+ `q64 wit` vs `qube wit`)

The compiler's introspection family. **These are `q64` commands, not `qube`
commands** — they introspect the *compiler's view of source* (IR, types,
effects, regions, layout, call graph, capabilities, world) over a single
`<file.q>` (+ `--module name=dir`), with **no manifest, no dependency
resolution, no registry**. That's the `q64`/`qube` split the repo already
draws: `q64` is the compiler over source; `qube` is the package tool over a
`qube.json5` (resolves deps, hits the Continuum, builds/publishes/runs). The
package-level WIT verbs (`qube wit show/extract/check/diff`) live in §"WIT —
first-class contract layer" rung 4 and are thin wrappers that resolve via the
manifest and call into these `q64` primitives — they don't duplicate them.

`show` dumps are **compiler-introspection: human/test-facing, not a stable
serialization** (same disclaimer as `show hir|mir|symbols`).

The surface (status against `spec/q64-cli.md` §"show"):

- [ ] `q64 show references <Type.method> --qube <file.q>` — find-usages /
      cross-references for a symbol (the inverse of the call graph). Needs the
      name-resolution pass (§"Semantic pass" Ladder A) to record use sites.
- [ ] `q64 show type <expr> --qube <file.q>` — the inferred type of an
      expression (the spec already reserves the "expression" subject form,
      `spec/q64-cli.md`). Gated on the type checker (Ladder A) — today typing is
      ad-hoc in `build_hir`.
- [ ] `q64 show regions <fn> --qube <file.q>` — the region/lifetime analysis
      for a function (which allocations land in which region — scope arena vs
      stack vs static; `spec/memory.md`). Surfaces the reclamation discipline.
- [ ] `q64 show layout <Type> --qube <file.q>` — the memory layout of a type
      (field offsets, size, alignment, canonical-ABI lowering). Pairs with
      struct-value support (§"Semantic pass" Ladder B) + `spec/memory.md`.
- [ ] `q64 show graph --qube <file.q>` — the call graph (and/or module import
      graph) of the qube; useful for effect propagation, dead-code, and the
      `references` inverse. Emit text + a `--json`/DOT form for tools.
- [ ] `q64 show denials <fn> --qube <file.q>` — reachability into
      `with_capabilities(deny:)` blocks (already specced; needs the
      `with_capabilities` syntax, tracked as `test.failing`).

### `q64 wit` (compiler primitives) vs `qube wit` (package wrappers)

WIT also splits along the same line. Decided: **the source↔WIT primitives are
`q64 wit`; the manifest/registry-aware verbs are `qube wit`.**

- [ ] `q64 wit export <src>` — synthesize the WIT world from source (a file or
      a `src/` dir) and write it out. This is the **export/emit** direction the
      compiler already does internally (`emit --component` writes `<base>.wit`,
      `show world --out` writes one file); `q64 wit export src/` is the explicit
      verb for "give me the world of this source tree" without a full
      `--component` build. Folds WIT rung 1's synthesis behind a first-class
      name.
- [~] `q64 wit import <world.wit>` — ingest a foreign/authored `.wit` (the
      **consume** direction). Parser + type mapping + binding preview + the
      scalar source-level call all landed (WIT rung 5 above); the remaining
      slice is rich-type (non-scalar) foreign calls.

## Semantic pass + struct values → static fits (the slope-changing ladder)

The ladder that took the compiler from 18 emitted diagnostic codes to **full
51/51 conformance** (now 53/53 with the operator codes) and gave it structs,
enums/`match`, faces/fits, and monomorphized generics. Most rungs are landed
(trail in git); what's below is the open remainder per ladder.

### Ladder A — semantic pass (name resolution + type checking)

- [ ] **A1 — symbol table + scopes.** In progress; the core slice landed
      (and PAR040 re-landed on name kinds in the check pass). Remaining:
      - [ ] Import-target resolution against `--module` sources (NAM001 /
            NAM006 at the sema layer).
- [ ] **A3 — `build_hir` consumes sema.** In progress:
      **A3 is structurally done**: build_hir consumes sema for signatures,
      expression types, and name lookup. What remains is *ownership of
      body scopes* (the Env bridge in build_hir adapts its wasm-slot
      Scope) — that collapses when the sema check pass lands with A4.
- [ ] **A4 — first real TYP codes + sema-emitted NAM.** In progress:
      - [ ] **NAM010 deferred — documented.** The corpus survey
            (`show symbols` over spec/tests + fixtures + examples) shows
            systematic false positives from not-yet-parsed forms: lambda
            params, `graph`/`channel` exprs, named args (`capacity: 16`),
            record-pattern fields, auto-prelude names (`sleep`). Unknown
            heads stay recorded-only until those land + an auto-prelude
            name table exists.
      - [ ] NAM010 / unresolved-type emission — still blocked on parser
            gaps (lambdas, graph/channel exprs, named args, record
            patterns, generic-param scoping), per the survey; the
            prelude table removed its share of false positives
            (corpus unresolved heads down, all remaining are parser-gap
            forms).

### Ladder B — struct values → static fits (after A3)

- [ ] **B2 — struct values in HIR/MIR.** SROA bindings, escaping-record
      layout, record params/returns, and B3/B4 (fit grammar, registration,
      static dispatch — golden `library-face-fit.q` runs) are all landed.
      Remaining boundary slices: nested structs (struct-typed fields),
      `str`/`ref` fields, whole-record interpolation/printing,
      `q64 show layout <type>`, and reclamation of escaped records
      (the scope arena never frees them — §"Memory reclamation").
- [ ] **B5 — generics beyond the first rung.** Monomorphization's v0
      floor landed with B4's close (one `<T: Face>` param, `[T]` slice
      params, record element types, void returns, statement calls), and
      const generics v0 landed too (`<const N: i64>` with `[T; N]` array
      params). Remaining: const generics beyond v0 (e.g.
      `Tensor<T, [A, B]>`-typed const generics — `matmul<T, const A, B, C>`
      with shape mismatch as TYP070, per the Tensor plan); generic
      structs (`Complex<T>` waits on this); then `dyn` dispatch
      (separate ladder).

### Ladder C — enums + `match` lowering

- [ ] **C — enums + `match`.** All v0 rungs are landed (trail in git):
      unit/payload/record/str variants, `Option`/`Result` prelude, enum
      returns + params, `if let`/`while let`, `T?` sugar, `try`
      (incl. Result-shaped `env.fs.read`), match in callee / void /
      record-returning bodies, exhaustiveness (TYP062) — plus the whole
      diagnostic ladder ridden to **51/51 full conformance** on the way.
      Remaining: pattern-grammar completion as it lands in `match`
      (guards, or-patterns, deep destructuring, range patterns —
      §"Other open items").

## Memory reclamation — Stack discipline on the implicit arena

The arena-never-frees era is over. Specced first
(`spec/memory.md` §"Frame reclamation (v0)"), then landed as a
**caller-side calling convention** — correctness never depends on an
analysis.

- [ ] **Known leaks (recorded in the spec):** a loop-iteration
      rebinding abandons its prior bytes; concat temporaries feeding a
      `let` (not a host statement) in `main`. Next rungs:
      per-iteration reset via the existing escape scan; explicit
      `scope { }` reset (parser: scope blocks are still unstructured).

## Numeric tower — floats

f64/f32, narrow-int storage, the native float-math builtins, and the
`q64.math` transcendentals are all landed (trail in git).

- [ ] **Receiver-expression / record-field float receivers** — float
      method dispatch beyond plain bindings (`p.x.floor()`,
      `make().len()`); the remaining tower breadth item.

## Wasm 3.0 feature audit

The audit is done and the decision recorded (Phase 2 above; matrix in
`spec/memory.md` §"Concurrency platform audit"). Remaining:

- [ ] Live `WebAssembly.validate` browser-probe harness — confirm the
      WebKit/iPad column empirically — plus maintainer sign-off on the
      v0 single-threaded cooperative-scheduler floor.

## C bindings

Compiler → C is done (Binaryen is vendored via `init.sh`, linked in
`q64/build.zig`, and `q64 emit` is the production codegen). The open
question is user-facing FFI:

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

- [ ] Spec the audio face wire format as the first concrete
      instance — drives the abstraction by example.
- [ ] Sketch the browser-host JS glue API (`runQ64`, capability
      injection, AudioWorklet bridge) so the debug page in
      [qube web] can render it.
- [ ] Cross-link from `env.md` and each face's spec.

## Other open items

This section grows as we go. Each item should have a checkbox so it's
visible at a glance whether it's been picked up.

- [ ] **`qube wit from-openapi <spec>` — OpenAPI → WIT.** Generate a WIT
      interface/world from an OpenAPI document, so a component can import an
      external HTTP API as a TYPED surface (paths → funcs, schemas → records,
      errors → result types) instead of hand-rolling fetch + JSON. Pairs with
      the wrapper/composition work on the qubepods side (the shell would
      synthesize the actual HTTP binding behind the generated imports). The
      reverse direction (WIT → OpenAPI for a deployed qube's exports) is the
      natural sibling — it gives every qube an OpenAPI doc for free, feeding
      agent discovery (QAD/MCP). The velocity win: spec-first API creation —
      write (or agent-generate) the OpenAPI doc, get the typed WIT surface,
      implement against stubs; building AND consuming APIs both get faster.
      Start with the subset OpenAPI 3.x ⇄ WIT can express cleanly; punt on
      oneOf/anyOf polymorphism until asked for.

- [ ] **Analyse: compile `wac` to wasm so `qube` can glue components together.**
      The Bytecode Alliance's `wac` tool (WAC language, `wac plug` /
      `wac compose`) composes Component Model components into one component —
      exactly the "glue several qubes' components" step. Investigate whether
      `wac` (Rust) can be compiled to wasm and called *from* `qube`, so
      composition needs no separate native binary and stays portable (CLI,
      web shell, qubepods builder). Questions to answer: does the
      `wac-graph`/`wac-parser` library surface build for a wasm target (vs
      wrapping the CLI); how inputs/outputs flow (in-memory bytes vs WASI fs);
      artifact size + compose speed on realistic qubes; and where it slots
      into the linking ladder / `q64 emit --component` output vs doing our
      own composition in-compiler.
      **The framing:** the real decision is *wac-as-wasm vs in-compiler
      composition*, and it hinges on how much composition qube needs. If the
      only operation is plugging one qube's exports into another's imports
      (the `wac plug` shape), a minimal Zig implementation over the component
      binary format is conceivable; the moment we want shared instances,
      virtualization, or multi-way composition graphs, that's reimplementing
      wac and the wasm-embedding route wins. Reusing `wac-graph` inherits
      upstream spec conformance as the Component Model evolves — component
      composition (merging type sections, resolving import/export shapes,
      instantiation order) is a different layer from our Binaryen core-module
      linking, and a large ongoing commitment to own. The wasm route also fits
      the architecture: both hosts already exist (the browser shell
      instantiates wasm next to `qube-resolve.wasm`; the native CLI runs it in
      the vendored wasmtime), whereas shelling out to a native `wac` binary
      kills the browser story and adds per-platform distribution.
      **PoC (do this FIRST — ~an hour, answers feasibility, feature skew, and
      size in one shot):**
      1. Compile `wac-graph` + a ~20-line Rust cdylib wrapper exporting
         `compose(component_bytes[]) -> component_bytes` (in-memory bytes, no
         WASI fs, no WAC-language parser) to `wasm32-wasip1`.
      2. Feed it two REAL `q64 emit --component` outputs — one of them the
         **async-lifted** export (legacy `[async-lift]`/`task.return`
         manglings, see the futures ladder) — under the vendored wasmtime.
         Async is the likely failure point: wac may reject async-lifted
         components outright, and if so the whole plan is gated on upstream.
         Do NOT PoC on a hello-world component; it proves nothing.
      3. Record: does it build; does it accept/compose our components; wasm
         artifact size (expect 2–5 MB); compose wall-time on realistic qubes.
      **If the PoC passes**, the design follow-ons: drive composition from
      qube manifests/deps via `wac-graph`'s `CompositionGraph` API (no WAC DSL
      for users); build `wac.wasm` once in CI and ship it as a prebuilt
      artifact like `q64-emit.wasm` (no cargo in anyone's qube build); later,
      maybe publish it as a qube on the Continuum (composing components with a
      component — self-hosting tooling).
- [ ] Pattern grammar completion — close the `(* open *)` markers in
      `grammar.md` §Patterns (guards, or-patterns, deep destructuring,
      range patterns, exhaustiveness).

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

Implementation:

- [ ] **`qube` CLI (build):** `addressSpace` required per target; build invokes
      `q64` once per address space; outputs under `target/<profile>/<addr>/`;
      `--addr` override; flag wasm64 builds as not-runnable-on-WebKit.
- [decided] **Single linear memory (multi-memory is a non-goal for now).**
      Codegen emits one memory; the `mem.*` segregation in `spec/memory.md`
      stays aspirational. Bulk-memory ops are enabled.
- [ ] **`q64 show memories`** reports the address space it emitted.
- [ ] **Continuum (optional, future):** additive prebuilt-artifact endpoint
      `/v1/qubes/{name}/{version}/artifact?addr=…` if the source registry
      should ever serve compiled variants (see continuum-api.md note).

## QView + reactive state + twins (architecture proof — NEW)

End-to-end POC, verified on iPad: q64 → wasm32 → WebGPU PWA + a q64-authored
backend twin. Design notes: [`spec/reactivity.md`](./spec/reactivity.md),
[`spec/agent-ui.md`](./spec/agent-ui.md).

The POC itself (qview host face, reactive `state` globals, backend twin in a
Durable Object, `@state(app)` generation v0, the address-width string ABI)
is done — trail in git. Remaining:

- [ ] **Browser-host glue for the wasm32 string ABI** — `runtime/web` +
      the qubepods hosts still need to read the i32 `env.out` args to
      exercise string programs in a real PWA (the wasmtime host already
      does).
- **`screen`/`draw` DSL** as real q64 syntax (the frontend language).
  - [ ] **Lowering.** `build_hir` synthesizes `main` (the `draw` block's widget
        calls + `qview.present()`) and an exported handler per `on <event>`
        (its body + re-emit the `draw` block + present — Stage-1 auto-redraw),
        resolving bare widget calls (`text(…)`) to `qview.*` host calls and the
        screen's `state` to the reactive globals. Then a real screen `.q` emits
        to the same wasm the hand-written `qview.*` form does today.
  - [ ] **`@state(scope)`** syntax + AST partitioning (client reads→subscribe,
        writes→command) builds on this.
- [ ] **`@state(scope)`** first-class syntax + a twin `face`/RPC API (typed
      methods beyond `inc`).
- [ ] **MSDF** text (corner-perfect) + the full retained `Renderer` face
      (`create_node`/`set_attr`/`mutate`).

## Conventions

- Tick `[x]` when done. Strike through and leave the line until the
  next sweep so we have a trail.
- Keep items terse — link to the spec / file / commit rather than
  re-explaining context here.
- New items append to "Other open items" by default; pull out into a
  named section when more than a few related items accumulate (as
  C bindings has).
