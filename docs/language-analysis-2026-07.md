# Q64 language analysis — July 2026

An assessment of where the language stands, measured against the bar set by
Julia and Mojo, and a prioritized set of improvements aimed at the domains Q64
wants to serve: AI, robotics, world models and digital twins, crypto, quantum
computing, and computational drug research.

Grounded in the spec (`spec/`), the compiler as implemented (`q64/src/`,
~46K lines of Zig), the stdlib (`stdlib/`), the examples corpus, and
`todo.md`'s phase ledger, as of `q64 0.0.6`.

---

## 1. Honest snapshot

### What is genuinely strong (and rare)

1. **The effect + capability system is a real differentiator.** No mainstream
   language makes "what this code can touch" a compiler-verified, published
   artifact: capability inference → Wasm custom section → manifest →
   Continuum disclosure → the component's WIT import list. The compile-time
   proof *is* the host-visible import surface (`spec/env.md`,
   `ir/effects.zig`). Julia and Mojo have nothing like it.

2. **Rate-typed dataflow + units.** `Signal<PCM<f32>, 48.kHz>`,
   dB with logarithmic algebra, `pre()`-gated feedback, channel policy
   chosen by temporal type, `@realtime` gating enforced through
   effect-polymorphic faces. This is Lustre-lineage synchronous dataflow
   fused with a modern type system — a niche neither Julia nor Mojo
   type-checks, and exactly the right substrate for sensors, audio, control
   loops, and token streams.

3. **Structured concurrency without function coloring.** One scheduler for
   all four surfaces (imperative / actors / dataflow / reactive), mandatory
   channel policies, ownership-moving sends. The cooperative-scheduler floor
   with CPS at statically-known suspend points is a sound engineering answer
   to the platform audit.

4. **Toolchain discipline.** Lossless CST, stable never-reused diagnostic
   codes with machine-applicable `repair` envelopes, byte-identical
   compiler-in-browser (`experiments/emit-wasm`), hand-rolled component
   emission validated by wasmtime, a live registry, and end-to-end
   verification of every landed rung on both wasm32 and wasm64.

5. **Agent-native design throughout.** Greppable keywords, no turbofish, the
   QView mutation protocol as an agent UI API, capability sandboxing
   (`with_capabilities(deny: …)`) as the safety boundary for generated code.
   This is a moat: Q64 is arguably the first language designed to be
   *operated by* AI agents, not just written with their help.

### The three gaps that define the situation

1. **The semantic middle is missing.** The compiler emits ~18–20 of 212
   specced diagnostic codes. There is no region pass (`q64/src/region/` does
   not exist), no effect-*assert* checking (`@pure`/`@realtime`/`@no_alloc`
   are parsed, not enforced), and typing is largely ad-hoc inside
   `build_hir.zig` (15.9K lines — the biggest file in the compiler). The
   flagship guarantees are currently promises, not proofs. `todo.md` knows
   this ("the slope-changing ladder").

2. **The numeric story is names without semantics.** `Simd`, `Tensor`,
   `DynTensor` exist only as prelude identifiers (`sema/prelude.zig:38-40`).
   The emitted Wasm feature set contains **no SIMD** (`codegen/emit.zig:920`),
   no GC, no threads. `q64.math` is 8 scalar f64 functions; there is no `ln`,
   no `pow`, no RNG, no complex numbers. (Unary minus and the
   `f64(i)`/`i64(f)` casts *do* work — verified against `q64 0.0.7`; the
   `0 - 1` idioms in older examples predate them.)

3. **No FFI and no autodiff — not even as designs.** `ffi.md` is unwritten;
   gradients appear nowhere in spec, stdlib, or todo. Every domain on the
   target list depends on at least one of these.

---

## 2. Julia and Mojo: what to copy, what to refuse

**Julia's lesson is ecosystem-by-interop.** Julia won scientific computing
before it had native libraries because `ccall` made C/Fortran (BLAS, LAPACK,
SuiteSparse) zero-cost from day one, and the REPL/notebook made
time-to-first-result minutes. Its composability came from generic functions
over a shared numeric tower — independent packages compose because they meet
at `AbstractArray` + operator generics.

**Mojo's lesson is that the IR is the product.** Mojo bet on MLIR: one
progressive-lowering path from portable code to CPU vector units and GPU
tiles, `SIMD[dtype, width]` as the bottom abstraction, and Python interop as
the adoption wedge. Its weakness is everything Q64 is strong at: no
sandboxing story, no capability model, proprietary until recently, and no
realtime/streaming semantics.

**What Q64 should refuse:** chasing Mojo on peak FLOPS through native
codegen *now*, or chasing Julia's dynamic dispatch. Q64's substrate is Wasm —
its product is *trustworthy, portable, realtime, agent-operable compute*.
That is a different (and defensible) quadrant. But "different quadrant" does
not excuse missing numerics: Wasm SIMD, threads-where-available, and a GPU
path via WGSL are all reachable without abandoning the substrate, and the
MIR `cfg` escape hatch already reserves the seat for a native LLVM backend
later.

**What Q64 should copy:**

- From Julia: interop-first bootstrapping (via the component model rather
  than `ccall`), a REPL/playground as the adoption surface (the
  compiler-in-browser work makes this uniquely cheap), and operator generics
  over a shared numeric tower so third-party qubes compose.
- From Mojo: `Simd<T, N>` as the honest bottom layer with real codegen;
  shape-carrying tensors monomorphized through const generics; kernel-style
  programming (tiling, fusion) as *library* patterns over those primitives —
  Q64's `@stage @fuse` is already the right hook.

---

## 3. The improvement plan, prioritized

### Tier 0 — foundations (blocks everything else)

1. **Finish the semantic pass** (todo.md Ladder A/B). A real typechecker is
   the gate for: effect-assert enforcement, region checking, generics beyond
   v0, field-aware LSP, and every domain claim below. Nothing in this
   document matters more.
2. **Enforce effect asserts.** `@realtime`/`@pure`/`@no_alloc` violation
   checking (EFF1xx) turns the realtime pitch from documentation into a
   compiler guarantee. This is cheap relative to its credibility value: the
   capability half already works (`ir/effects.zig`); the assert half is the
   same propagation lattice with the arrows reversed.
3. **Const generics.** `Tensor<T, [A,B]>`, `Simd<T, N>`, rate-typed
   `Signal<T, 48.kHz>`, and qubit-register types all sit behind this one
   feature (`spec/generics.md` has the design; only the type kind exists).
4. **Pin operator overloading.** The mechanism (compiler-blessed
   `Add`/`Mul`/`Neg` faces) is an open grammar item. Without it there is no
   ergonomic numeric library, period. Resolve it now, in the faces framework,
   with laws attached (`law associative`, `law distributive` — the property
   -test machinery is already specced).
5. **Numeric ergonomics tail.** Unary minus, the `f64(i)`/`i64(f)` casts,
   and the f32 builtin set have already landed; what remains is
   receiver-expression / record-field float receivers for the math builtins
   and the transcendentals gated on loadable stdlib qubes (both already
   tracked in `todo.md` §"Numeric tower").

### Tier 1 — the numeric core (the Julia/Mojo table stakes)

6. **Make `Simd<T, N>` real.** Emit Wasm SIMD128 from a `Simd` type whose
   lane ops lower to `v128` opcodes. Relaxed SIMD where the host audit
   allows. This is the single biggest performance lever available inside the
   Wasm substrate, and Binaryen already supports the instructions — the
   feature flag is currently just not set.
7. **Make `Tensor` real, in two stages.** Stage 1: static-shape tensors as
   monomorphized structs over `Simd` kernels — shape errors at compile time
   (TYP070), `matmul<T, const A, B, C>` as the milestone. Stage 2:
   `DynTensor` with runtime shape and a strided-view protocol. Broadcasting
   rules copied from NumPy semantics but *checked* where shapes are static.
8. **Expand `q64.math` to a credible core**: `ln/log2/log10/pow/atan2`,
   f32 variants, complex numbers (`Complex<T>` — a prerequisite for FFT,
   quantum simulation, and signal processing), and a seeded, splittable RNG
   surfaced through `env.random` so determinism stays capability-visible.
9. **The BLAS/linalg boundary face.** The stdlib design already says "large
   shapes → host BLAS/WebGPU/WebNN via the runtime adapter — an explicit
   boundary crossing." Spec that face (`q64.linalg` backed by `env.compute`)
   and implement it in the wasmtime host first. An explicit, effect-visible
   "this leaves Wasm" boundary is *better* than Julia's invisible ccall — it
   fits the audit story.
10. **Low-precision dtypes.** `f16` is specced; add `bf16` (and keep the
    arbitrary-width integers — `u4`/`i4` are a genuinely good fit for
    quantized inference that neither Julia nor Mojo expresses as naturally).

### Tier 2 — compute at scale

11. **q64 → WGSL compute kernels.** The gfx README already promises "shaders
    written in q64, compiled to WGSL — not embedded as strings." Generalize
    that from shaders to *compute*: a `@gpu` (or `@kernel`) effect marks
    functions compiled to WGSL; the same MIR feeds a WGSL emitter (it is
    structured control flow already — a much better match than emitting from
    a CFG). WebGPU is the only GPU API that satisfies the iPad-floor
    constraint, and it runs on Vulkan/Metal/D3D12 natively via Dawn/wgpu on
    the wasmtime host. This is Q64's honest answer to Mojo's GPU story:
    portable-first, native-quality later.
12. **WebNN / host-inference adapter** for the `q64.ai` surface: the
    `Model<InVocab, OutVocab>` typed façade delegating to WebNN (browser) or
    GGML/ONNX-runtime (native host) through one capability face
    (`env.ai.infer`), keeping `@inference` in the manifest. Token streams
    then flow into the existing `Stream<Token<V>, R>` design — the
    voice-agent flagship becomes buildable end-to-end.
13. **Autodiff: design now, build after Tier 1.** Write `spec/autodiff.md`.
    Q64 has unusual structural advantages for source-transform reverse-mode
    AD: a backend-neutral two-tier IR to transform, `@pure` to delimit
    differentiable regions, regions/arenas for tape allocation, and faces to
    make `Differentiable` a lawful contract. A `@differentiable` marker with
    `grad(f)` as a comptime operator over HIR puts Q64 in Enzyme/Zygote
    territory *with effect-checked purity* — something Julia cannot promise.
    Without this, "support for AI" means inference only.
14. **Threads on capable hosts.** The Phase-2 audit already scoped this as
    an upgrade behind the same scheduler. Data-parallel `Tensor` ops and the
    actor runtime are the two consumers that justify it.

### Tier 3 — interop and surface

15. **Write `ffi.md` — the component model *is* the FFI.** Two layers:
    (a) core-module linking against wasm-compiled C/C++/Rust libraries
    (BLAS, RDKit, SQLite, crypto primitives all compile to wasm today) with
    `extern` imports typed in q64; (b) WIT ingestion (already Phase 6) so any
    published component becomes a typed, capability-disclosed dependency.
    This is the ecosystem-bootstrap lever — Julia's `ccall` lesson, executed
    with 2026 infrastructure and *sandboxing preserved* (a vendored C library
    in Q64 cannot exfiltrate: it has no capabilities unless granted — a
    security property Julia/Python fundamentally cannot offer for native
    extensions).
16. **REPL / playground as the adoption surface.** `emit-wasm` already
    compiles byte-identical wasm in the browser. A persistent-session REPL
    (recompile + re-instantiate with state snapshot from the arena — regions
    make this tractable) plus the QView plotting primitives = the "time to
    first plot" experience that drove Julia adoption, running on an iPad.
17. **Open the units system to SI.** The closed six-dimension set (Time,
    Frequency, Information, Angle, Samples, Gain) is right for audio but
    fails science: no Length, Mass, Temperature, Current, Amount (mol),
    Luminosity. Extend `spec/units.md` with the full SI base set (still a
    closed, compiler-known list) and allow derived composites (N, Pa, J, V).
    Robotics (m/s², N·m), drug research (mol/L, kDa), and digital twins all
    need this, and the phantom-type machinery already exists.

---

## 4. Domain-by-domain

### AI

- **Now**: Tier 1 + item 12 make typed inference real: `Token<Vocab>` /
  `Model<In, Out>` (vocab mismatch as a compile error) over a host-inference
  face, tokens as `Stream<Token<V>, R>` through the graph runtime. The
  arbitrary-width ints cover quantization; `bf16` covers weights.
- **Next**: autodiff (item 13) for on-device fine-tuning/LoRA-class training.
- **The moat is agent-operability, not FLOPS**: machine-applicable `repair`
  diagnostics, the QView agent-UI protocol, and — above all — capability
  sandboxing as the answer to "how do you safely run AI-generated code."
  Q64 should market itself as *the language agents write and hosts trust*:
  `with_capabilities(deny: …)` around generated qubes is a product, not a
  feature. Lean into the closed loop: agent writes q64 → compiler returns
  structured diagnostics with repairs → agent fixes → capability audit gates
  deployment.

### Robotics

- The core is *already correctly shaped*: `@realtime` (enforced — Tier 0
  item 2), rate-typed `Signal` for sensor fusion (IMU at 1.kHz, camera at
  30.Hz — cross-rate mixing is a compile error), `pre()` for control-loop
  feedback, pool-backed channels, `trap()` on the hot path.
- Missing: **hardware capability faces** — `env.gpio`, `env.i2c`, `env.can`,
  `env.serial`, `env.camera` — one spec each, implemented first on a
  Linux/wasmtime host. The capability model is a *safety* story here
  (a motor-control qube that cannot touch the network is auditable at the
  manifest level).
- Missing: the SI units (item 17) for kinematics/dynamics types.
- Bridge, don't rebuild: a `ros2` adapter qube (DDS via the host) and a
  WAMR/embedded profile (the docs already name WAMR as a fallback host) get
  Q64 onto real controllers. The deferred `@realtime` cycle-budget
  annotation (`spec/effects.md`) is worth reviving as the WCET story.

### World models & digital twins

- **The twin is already a language primitive** — `@state(room r)` desugaring
  to a Durable-Object-backed actor with diff fan-out is precisely a digital
  twin: a live, addressable, subscribable stateful mirror. Name it that in
  the docs and product; the overlap with the qubepods `apps/twin`
  ProjectTwin DO is an ecosystem asset.
- Determinism is Q64's structural advantage: *all* nondeterminism enters
  through capabilities (`env.time`, `env.random`). A `@deterministic` build
  profile — seeded `env.random`, virtual `env.time`, recorded capability
  log — gives record/replay simulation for free, which no mainstream
  sim language offers as a compiler property. Fixed-timestep synchronous
  ticks are already the stream semantics.
- Arenas make **snapshot/rollback** tractable (copy the arena, restore the
  arena) — the primitive under prediction, branching futures, and "what-if"
  twin queries. Add a `snapshot()`/`restore()` region operation.
- The remaining need is an ECS-flavored stdlib qube over `Pool<T, N>`
  regions + the quine/scene integration that already exists at the QView
  `scene` kind.

### Crypto

- **Blockchain**: deterministic, metered, capability-sandboxed Wasm is
  already the smart-contract substrate (CosmWasm, NEAR, Polkadot ink!,
  Arbitrum Stylus). Q64 needs: `u128`/`u256` (extend the arb-width integer
  tower past 64 — the one place "64-bit only" should bend), a
  no-float-no-clock deterministic profile (the `@deterministic` build above,
  minus even `env.time`), and gas-metering compatibility (Binaryen
  instrumentation pass). A `qube deploy --target cosmwasm|stylus` backend
  would make Q64 a *safer-by-construction* contract language — effects and
  capabilities map directly onto contract permission models.
- **Cryptography**: a `@const_time` effect assert (no secret-dependent
  branches or memory indexing — checkable on MIR, in the same family as
  `@no_alloc`) would be a genuinely novel, publishable differentiator; no
  production language enforces constant-time at the type level. Primitives
  themselves come via the FFI path (wasm-compiled libsodium/HACL*) rather
  than reimplementation — HACL*'s verified C compiles to wasm today.

### Quantum

- Keep it a **library, not language core**. The prerequisites are all
  Tier 1: `Complex<T>`, `Tensor`, const generics. Then `q64.quantum`:
  `QReg<const N: i64>` (qubit count in the type — the same trick as sample
  rates), gate application as face-checked ops, `law unitary` property
  tests, OpenQASM 3 emission through the component boundary for real
  hardware, and a state-vector simulator over complex tensors (a `@gpu`
  kernel showcase, item 11) for development. This is Qiskit-shaped, with
  compile-time register-size errors Python cannot give.

### Drug research

- The realistic wedge is **typed pipelines over interop**, not rebuilding
  chemistry. RDKit and OpenMM-class engines arrive via the FFI path (item
  15 — RDKit already compiles to wasm as "RDKit.js" MinimalLib); Q64
  contributes what Python pipelines lack: unit-checked quantities (mol/L,
  kDa, Å — item 17), `Stream`-typed screening pipelines with backpressure
  and capability-audited data access (a real concern for proprietary
  compound libraries — the identity-pinned `env.kv`/`env.db` faces are
  exactly the multi-tenancy story a pharma deployment needs), and
  deterministic, replayable workflows (the digital-twin machinery above,
  applied to *in silico* experiments).
- GPU MD kernels are a *far* milestone behind items 11/13; do not lead
  with them.

---

## 5. What NOT to do

- **Don't add a second numeric-array world.** One `Tensor`, one `Simd`,
  operator faces on both; everything else (images, frames, audio buffers,
  quantum states) is a newtype/kind over them. Julia's composability came
  from exactly this discipline; the stdlib READMEs already point this way.
- **Don't build native codegen before the semantic pass is done.** The MIR
  `cfg` escape hatch preserves the option; exercising it now would fork
  effort while the typechecker — the actual bottleneck — waits.
- **Don't open user-defined effects or region kinds yet.** The closed sets
  are what make the audit story legible to hosts and agents. Extend the
  closed sets (SI units, `@const_time`, `@gpu`) deliberately instead.
- **Don't chase a Python-interop wedge.** That is Mojo's war. Q64's wedge is
  the component model + capability security + the agent loop; interop means
  *WIT ingestion and wasm-compiled libraries*, not CPython embedding.
- **Don't let the spec keep outrunning the compiler unboundedly.** The
  spec-to-implementation ratio is currently the project's biggest risk;
  every new spec (autodiff, ffi, quantum) in this plan should land with a
  first compiler slice in the same phase, per the repo's own rung
  discipline.

---

## 6. Suggested sequencing (phase-ledger form)

| Phase | Contents | Unlocks |
|---|---|---|
| **N** (with Ladder A/B) | typechecker; effect-assert enforcement; const generics; operator faces; numeric ergonomics | every guarantee the docs already claim |
| **N+1** | Simd→SIMD128 codegen; static Tensor + matmul; math expansion (ln/pow/complex/RNG); f16/bf16; SI units | credible numerics; quantum/robotics type foundations |
| **N+2** | `ffi.md` + wasm-library linking; WIT ingestion; linalg/compute host face; REPL over emit-wasm | ecosystem bootstrap; science adoption surface |
| **N+3** | WGSL kernel emission; WebNN/host-inference face; threads upgrade; `spec/autodiff.md` + first slice | AI training/inference; GPU story |
| **N+4** | `@deterministic` profile + arena snapshot/rollback; hardware faces (gpio/can/serial); u256 + `@const_time`; contract target spike | twins/world models; robotics; crypto |

The through-line: **finish the semantic core, make the numeric tower real,
then let every domain arrive as library qubes over four primitives — Tensor,
Signal, capability faces, and twins — with the effect system as the trust
layer that Julia and Mojo structurally cannot match.**
