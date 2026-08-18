# Audio roadmap — making q64 a real DSP language

Status: roadmap (2026-08). Companion to `docs/language-analysis-2026-07.md`;
sequences the audio-specific work across compiler, stdlib, and runtime.
Audio is the workload the language was designed around — `@realtime` in
`spec/effects.md`, `Signal<PCM<f32>, R>` in `spec/streams.md`, the pool-backed
worked examples in `spec/memory.md` §"Real-time audio path" — but almost none
of it is implemented yet. This note is the order of implementation, chosen so
each phase produces something runnable and measurable.

## Where we stand

The spec half is unusually audio-complete; the implementation half is not.
The honest gap list, per subsystem:

| Subsystem | Spec | Implementation today |
|---|---|---|
| `@realtime` assert lattice (`spec/effects.md`) | complete | parsed, **not enforced** (`q64/src/effect/` is a README) |
| Regions: `Pool`/`Arena`/`Stack` (`spec/memory.md`) | complete | no region pass (`q64/src/region/` is a README); two bump allocators, no free |
| `Signal<T, R>`, `pre()`, `@fuse`, STR060 (`spec/streams.md`) | complete | no graph runtime, no pipe codegen |
| `Simd<T, N>` (`spec/types.md`) | complete | `f32x4`/`i32x4` splat/extract/`add`/`mul` only; no slice load/store, no struct fields, no cross-function values |
| Optimizer | — | Binaryen linked, **no optimization pass ever runs** |
| `stdlib/math` | — | f64-only transcendentals; no f32 tier, no fast tier |
| `stdlib/audio` | README | empty |
| `env.audio` face | named in `spec/env.md` | no wire format (todo.md §"Host ABI for non-trivial faces": "spec the audio face wire format as the first concrete instance") |
| `runtime/audio-host` | README (VST3/AU/AAX/CLAP) | not implemented |
| Benchmarks | — | none anywhere in the repo |

Two spec decisions turn out to be exactly right for the delivery targets and
must be preserved through everything below:

1. **`@realtime` functions never cross a component boundary**
   (`spec/effects.md` §`@no_component_lift` — canonical-ABI lifting
   allocates). Audio plugins are therefore **core wasm modules with a raw
   ABI**. That is precisely the shape of WCLAP (CLAP-in-wasm, the open
   browser plugin format at plinken.org) and of a native CLAP shim. No
   design change needed — the plugin story falls out of the existing rule.
2. **wasm32 is the browser baseline** (the address-space decision recorded
   in the qubes workspace README). Browser audio — AudioWorklet, WebKit,
   iPad — is wasm32. Every phase below must work on wasm32; wasm64 is a
   bonus, never a prerequisite.

The delivery budget to keep in mind: an AudioWorklet render quantum is
128 frames ≈ 2.67 ms at 48 kHz, shared across every plugin in a chain.

## Phase A — foundations: measure, then stop shipping unoptimized code

Everything later is judged by numbers this phase creates.

**A1. Benchmarks first.** *(Landed 2026-08 — see `bench/`.)* A `bench/`
suite of DSP microkernels — biquad chain, FIR, wavetable oscillator, block
mix/gain, soft-clip — compiled by `q64 emit` and timed under the vendored
wasmtime and a headless browser, against a Rust `wasm32-unknown-unknown`
baseline of the same kernels. CI publishes the ratios. There are currently
zero benchmarks in the repo; until this exists, every performance claim is
folklore. *(First results overturned two assumptions: the 60–300× "q64 is
slow" numbers were a Debug-built host — `bench/README.md` finding 1 — and
debug-mode q64 codegen is already at parity with release Rust on
register-resident kernels.)*

**A2. Turn the optimizer on.** *(Landed 2026-08 — `q64 emit --release`,
`-O2` speed-focused with wasm-level inlining disabled by measurement; see
`bench/README.md` finding 3. Not yet surfaced as a `qube build` profile.)*
`q64/src/codegen/emit.zig` builds Binaryen expression trees and serializes
them without ever calling `BinaryenModuleOptimize`. Add a `--release` mode
on `q64 emit` (surfaced as a `qube build` profile) that runs the standard
pass pipeline. Debug builds stay pass-free so the byte-identical
differential test in `experiments/emit-wasm` keeps its meaning (scope it to
debug mode). The known lowering redundancies — unconditional
aggregate-result `memory.copy` slides, per-call `sp` watermark save/restore
— are exactly what these passes clean up; hand-fixing them in the lowerer
is phase-C work only if the numbers say Binaryen didn't.

**A3. Finish `Simd` for DSP.** *(Slices 1–3 landed 2026-08: the f32x4
lane-op surface is complete — `add`/`sub`/`mul`/`div`/`min`/`max`,
`neg`/`abs`/`sqrt` — `Simd.load(v, i)` / `x.store(v, i)` move four lanes
to/from a `Vec<f32>` with one inline bounds check per group, `Simd` values
cross function boundaries as params and returns, `v.replace(n, x)` sets a
lane, and `a.mul_add(b, c)` emits the relaxed-SIMD fused madd — ~20× over
Rust-on-wasm's `fmaf` libcall on the `biquad_bank4` kernel, bit-identical
results on FMA hardware; see `bench/README.md` finding 4. Struct fields
and f64x2 remain.)* In dependency order:
- loads/stores between `Simd<f32, 4>` and `[f32]` slices — without this
  SIMD cannot touch an audio buffer at all;
- the full `f32x4` arithmetic set (`sub`, `div`, `neg`, `abs`, `min`,
  `max`, `sqrt`), lane insert, shuffles;
- `Simd` values as struct fields and across function boundaries (filter
  state lives in structs; kernels are functions);
- relaxed SIMD behind a feature flag for `relaxed_madd` — FMA is the
  single largest win for IIR/FIR inner loops;
- `f64x2` for mastering-precision paths.

**A4. An f32 + fast tier in `stdlib/math`.** The existing surface is
f64-only at a ≈1e-9 target. Audio wants a documented second tier: f32
variants, and `*_fast` approximations (`tanh_fast`, `exp_fast`,
table-based `sin`) with stated error bounds. A saturation curve does not
need 1e-9; it needs a handful of cycles.

Exit criteria: benchmark suite in CI; release-mode kernels within ~1.5× of
the Rust baseline scalar-for-scalar; SIMD biquad demonstrably faster than
its scalar form.

## Phase B — make `@realtime` true

The language's central audio claim — "audio-thread safe, verified at
compile time" — is currently parsed and ignored. This phase makes the
assert half of `spec/effects.md` real.

**B1. Intra-procedural assert checking.** *(First enforcement landed
2026-08: `q64 check` verifies a declared assert set — closed under the
implication graph — against the body's operations and its callees,
emitting EFF100/EFF101/EFF110/EFF112; declared sets for annotated callees
per the spec's subset rule, scanned transitive facts for unannotated
ones. Token-scan level in `sema/check.zig`, same-file resolution; the
HIR-level pass subsumes it later. Every `bench/` kernel's `pass` carries
a checked `@realtime`.)* Enforce `@no_alloc`,
`@no_suspend`, `@no_panic` (and therefore `@realtime` via the implication
graph) against the operation table in `spec/effects.md` §"What breaks
which assert", propagated through the existing capability-inference
fixpoint. The carve-outs matter as much as the bans:
`env.time.monotonic_ns()`, `env.random.fill_bytes(buf)`, and
`env.audio.write_pcm(buf)` on a pool-owned buffer stay callable. This does
not need the full region pass; it needs the operation classification the
spec already wrote down, emitting EFF1xx codes.

**B2. `Pool` and `Arena` as real region kinds.** The audio architecture in
`spec/memory.md` — audio thread reads from `Pool`-backed channels,
operates on already-positioned buffers, allocates nothing — requires
`Pool<T, N>` allocate/release and named `Arena` regions to exist. Scope:
enough of the region pass to type `Vec<T, R>`/`Box<T, R>` against a named
region and reject escapes (REG010); full `transfer` semantics can lag.

**B3. Caller-provided buffers.** *(Landed 2026-08 on the v0 carrier:
`fn process(input: Vec<f32>, out output: Vec<f32>, g: f32, n: i64)
@realtime` compiles, checks, and runs — Vec parameters carry their element
type (f32 cells), the `out`/`ref` parameter mode makes the buffer
writable (writing through a modeless vec param is ImmutableAssign), and
`Simd.load`/`store` work on parameter buffers. The `process_buf` kernels
measure the boundary at ~zero cost vs the same loop inlined in `main`.
The `[f32]`-slice spelling arrives with real slices.)* Make the `out`
parameter mode work for `[f32]` slices, so
`fn process(input: [f32], out output: [f32]) @realtime` is expressible
and allocation-free — the universal DSP signature.

Exit criteria: the `spec/tests/` conformance cases for EFF101/EFF102/
EFF110/STR060 flip from `.todo` to green; a deliberately-allocating
`@realtime` function is a compile error with the specced diagnostic.

## Phase C — the compiler advantage: block-compiled stream graphs

This is the phase where writing DSP in q64 becomes *better* than writing
it by hand, not just possible. Precedent (unoriginality is a feature):
Faust, SOUL, and Cmajor all compile a per-sample dataflow description into
one monolithic `process(block)` function over a flat state struct. q64's
stream layer should do the same for any maximal `@realtime` subgraph:

- **Semantics stay per-tick** — the synchronous model of
  `spec/streams.md`, `pre()` for feedback — but **codegen emits a single
  fused loop over a block of N frames**, all stage state in one
  arena-resident struct, no channels, no scheduler, no per-sample dispatch
  on the audio thread. Channels and their policies remain the semantics at
  the graph's *edges* (parameter input via `LatestValue`, meter output via
  `SharedSignal`), never inside it.
- **Fusion is the default inside a `@realtime` region.** The opt-in
  `@fuse` stance exists for task-boundary predictability; inside a graph
  pinned to one thread by definition, there is no boundary to predict.
  `@fuse` stays as the cross-task operator elsewhere.
- **Block size is a runtime parameter** of the generated `process`, not a
  type parameter. AudioWorklet gives 128 today and is moving to variable
  quanta; native hosts pass anything from 32 to 2048. Sample *rate* stays
  in the type (`Signal<T, R>`); block *size* does not.
- The fused loop is the natural consumer of phase A's SIMD: state in
  struct-of-arrays layout where lane-parallel, `relaxed_madd` in the
  filter kernels.

Alongside it, **`stdlib/audio` v1**, prioritized for plugin building
*(first slice landed 2026-08: `one_pole`, DF2T `biquad`, `saw`, caller-owned
`delay_tick`, `soft_clip`, `tanh_fast`, `denormal_flush`, `clamp1` — all
f32, stateful processors as structs with fit methods, per-sample free
functions `@realtime`-checked; `examples/audio-dsp` renders a voice through
them offline. Unblocked along the way: stateful fit methods (`self.y = …`),
record bindings from constructors inside callee bodies, and cross-module
method dispatch. SVF, envelopes, poly-BLEP, resamplers, FFT, and the
coefficient-design helpers — which want `q64.math`'s f32 tier — remain)*:
biquad + state-variable filter, delay line, poly-BLEP oscillators,
envelopes, one-pole parameter smoother; FFT deliberately last (hardest,
least needed for first effects). Two rules baked in from the start:

- **Denormal flushing everywhere recursive.** Wasm has no FTZ/DAZ mode; a
  decaying filter will reach denormals and can run orders of magnitude
  slower. Every stdlib filter flushes its state (offset or bit-mask
  idiom), and `stdlib/audio` exports the helper so user code can too. A
  library function, not a new effect — new effects are compiler+runtime
  changes and this doesn't need one.
- **Property tests over golden numbers** (bounded output, DC-correct,
  monotone envelope), reproducible via the deterministic profile
  (`docs/deterministic-profile.md`).

And the missing example: `examples/audio-dsp/` — the small synth + effects
chain `examples/README.md` already promises — compiled to wasm and rendered
offline (deterministic golden render) plus live in the browser host.

Exit criteria: a `graph { osc |> filter |> gain }` compiles to one
`process(block)` function whose inner loop the benchmarks place at parity
with the hand-written stdlib kernels it fuses.

## Phase D — delivery: `env.audio` and a plugin target

*(First delivery step landed 2026-08 ahead of D1–D3:
`examples/audio-web` puts q64 audio in a browser — the `q64.audio` voice
compiled to wasm32, called from a page through a plain `pub fn
render(…) -> i64` export returning a `buf.ptr` address, played via the Web
Audio API with live frequency/cutoff/drive sliders (~100 ms per 2-second
debug render). It is the offline-render half of the browser story and
needed no new ABI; the live AudioWorklet half — `examples/audio-worklet` — followed: one
persistent q64 instance on the audio thread, `process(ref st, out io, …)`
per 128-frame quantum (~2 µs/quantum debug), state in guest `Vec<f32>`
buffers the host re-enters by header address via the new `v.head`
surface, parameters smoothed in-guest. That is the WCLAP shape minus the
CLAP ABI; D1–D3 below add the ABI.)*

**D1. Spec the `env.audio` wire format** — the recorded next step in
todo.md §"Host ABI for non-trivial faces", and the first capability face
too structured for a raw ptr+len convention. Proposed shape, to be pinned
as `spec/audio-face.md`:
- **planar (non-interleaved) `f32` buffers** in guest linear memory at
  pool-owned addresses negotiated once at activation — stable addresses
  are what keep `env.audio.write_pcm(buf)` `@realtime`-typed (no per-call
  allocation or copy decisions);
- block size passed per process callback, not fixed at activation;
- parameters as `id → f64` with guest-side smoothing (the stdlib one-pole);
- MIDI/events as a length-prefixed queue in a `RingBuffer` region.

Planar f32 matches Web Audio, CLAP, and `Simd<f32, 4>` lanes
simultaneously.

**D2. Codegen prerequisites for a C-shaped plugin ABI.** The emitter
currently produces no function tables and no `call_indirect` anywhere
(closures inline, HOFs become loops). A CLAP-family target needs:
- funcref table emission with element segments, the table **exported and
  growable (no declared max)** — hosts grow the plugin's table to install
  callback trampolines, and a capped table fails at load;
- exported `malloc`/`free` serving from the persistent heap — hosts
  allocate id strings and event lists inside plugin memory at setup time,
  never on the audio path;
- vtable structs in linear memory whose fields are table indices.

*(Landed 2026-08, scoped to the wrap: `q64 emit … --wclap`
(`q64/src/codegen/wclap.zig`) synthesizes all three as a read-back
post-pass — an exported growable funcref table (initial 19, max 1024;
slot 0 left null so hosts that null-check fn pointers stay honest), a
16-byte-aligned bump `malloc`/`free` over a private region at 3 MiB
(disjoint from the guest vec heap at 1 MiB), and the CLAP vtable structs
written into a scratch block at 896 KiB by a start-chained data-init.
The general emitter still produces no tables — `call_indirect` lands
when the language needs it, not before.)*

**D3. The `wclap`/`clap` build target.** None of D2 surfaces in the
language — q64 rejects a C ABI on purpose, and plugins don't need one.
`qube.json5` already specs `host: "audio-host"` with `formats:`; the
compiler synthesizes the entire CLAP shim from a declared plugin surface
(a `fit X : AudioPlugin` face: `@realtime` process, a parameter
declaration, optional UI entry) the same way it already synthesizes WIT
worlds from the `pub` surface. Target order:
1. **WCLAP** (CLAP-as-wasm, wasm32, runs in the open reference browser
   host at plinken.org) — smallest ABI, browser-deliverable, and the
   AudioWorklet path exercises the real 128-frame budget;
2. **native CLAP** via `runtime/audio-host` (same vtable, native build);
3. AU/VST3 wrappers around the identical graph, much later.

The conformance check must be an honest host: discover ports through the
audio-ports extension, allocate through the plugin's own `malloc`, drive
the real lifecycle — a validator that reaches into module internals passes
for the wrong reasons and ships broken artifacts.

*(WCLAP rung landed 2026-08 — `examples/audio-wclap`: the audio-worklet
voice wrapped by `--wclap` into a single wasm module exporting
`clap_entry` (i32 global), `memory`, growable `__indirect_function_table`,
`malloc`/`free`, with `clap.plugin-factory`, the full plugin lifecycle,
and `clap.audio-ports` (one stereo output, 276-byte info) served from
synthesized shims; the process trampoline builds a `Vec<f32>` header over
the host's channel-0 buffer (the `v.head` re-entry model, zero-copy) and
mirrors channel 1. Validated by `check.mjs`, an honest minimal host per
the rule below: 400 blocks, energy matches the worklet reference
(~84.7/block), state persists, table grows.

`clap.params` followed: two automatable parameters (Frequency 20–2000 Hz,
Drive 1–4) served by the full six-function extension, param-value events
read from `in_events` by `call_indirect` through the host-installed
size/get trampolines — the first host→plugin callback path, and the
concrete reason the growable table exists — values block-snapped (the
recorded deferral) and clamped, applied via `process` and `flush` alike;
the guest's in-state one-pole smoothing de-zippers automation with no
shim work. The validator installs real trampolines (tiny compiled wasm
shims, as `wclap-host-js` does) and asserts the *audio* moved: measured
110.0 Hz at default, 220.0 Hz after the event. The parameters are
shim-defined pending the declared `fit X : AudioPlugin` surface
(D1/`spec/audio-face.md`); the filter stays fixed until then
(coefficients need trig the shim shouldn't synthesize). Native CLAP and
AU/VST3 remain.)*

Exit criteria: the phase-C example builds as a `.wclap`, loads in the
reference browser host, and processes audio inside budget; `q64 show
world` on a plugin qube shows the audio face as its complete import
surface.

## Phase E — later, each gated on the phases above

- **Threads and voice pools** over `@shared` + `SharedSignal`
  (`spec/memory.md`): not needed for plugins — an AudioWorklet is
  single-threaded and the v0 cooperative floor matches it — but needed for
  engine-scale polyphony on capable hosts.
- **`@realtime(< 1.ms)` budget annotations** — the open item already
  recorded in `spec/effects.md`; becomes checkable once benchmarks give
  per-kernel cost models.
- **WGSL kernels** (`docs/wgsl-kernels.md`) for offline render and
  convolution-scale work; never on the real-time path.
- **Interleaved/int PCM kinds** (`PCM<i16>` etc.) with explicit
  conversions, for file I/O and codec edges.

## Open items deferred

- The exact `AudioPlugin` face surface (parameter declaration syntax,
  preset/state hooks, UI entry point) — pin when D3 starts, informed by
  D1's wire format.
- Whether relaxed SIMD's nondeterminism (fused vs unfused rounding) is
  acceptable under the deterministic profile, or `--deterministic` forces
  the strict forms.
- Per-sample-accurate parameter automation vs block-boundary snapping in
  the fused loop — CLAP supports sample-offset events; v1 can snap.
- Whether the block-compiled graph's state struct participates in region
  snapshot/rollback (`docs/deterministic-profile.md`) for plugin state
  save/load, or state save is a separate serialization pass.
- Restoring the pre-spec design narrative into `docs/history/` — the
  tombstoned design repo points here, but the directory doesn't exist yet;
  the audio rationale (PCM kinds, fusion, the audio-host matrix) lives
  only in that repo's git history today.
