# bench — DSP kernel benchmarks

Phase A1 of [`docs/audio-roadmap.md`](../docs/audio-roadmap.md): seven audio
microkernels written twice — in q64 (`kernels/*.q`) and in Rust
(`baseline-rust/`) — compiled to wasm32 and timed under the repo's own
toolchain. Until this existed there were zero benchmarks in the repo; every
performance claim was folklore. The point is not the absolute numbers (they
are machine-relative) but the **ratios**, and what they attribute the gap to.

## Run it

```sh
./init.sh                                                  # vendor/ toolchain
(cd q64 && zig build)                                      # the compiler
(cd runtime/wasmtime && zig build -Doptimize=ReleaseFast)  # the embedded host
rustup target add wasm32-wasip1                            # the baseline's target
./bench/run.sh
```

The host build mode is load-bearing — a Debug-built host executes some guest
loops ~100× slower (finding 1), so `run.sh` starts with a calibration probe
(`calibrate.q`) and refuses to print numbers from a slow host.

Each kernel self-times with `env.time.monotonic_ns()` (q64) /
`Instant::now()` (Rust): 7 passes, minimum reported, so process startup and
compilation never pollute the numbers. Kernels print one
`bench <name> samples <n> ns <t> check <c>` line; `run.sh` joins the two
sides into a ns/sample table.

**The checksums are part of the contract.** Every Rust kernel mirrors its
`.q` twin operation-for-operation — same input recurrences, same
coefficients, same accumulation — so matching checksums prove both sides ran
the same math and neither side's compiler deleted the work. A divergent
checksum is a bug in the benchmark, and a "fast" number with a wrong
checksum is not a result.

## The kernels

| Kernel | Shape | Why it's here |
|---|---|---|
| `mac_f32` | serial multiply-accumulate, 1 chain | the floor: latency-bound, ~6 locals |
| `mac_simd4` | the same on `Simd<f32, 4>` | measures the v0 Simd slice directly |
| `clip_simd4` | branch-free cubic clip on `Simd<f32, 4>` | the full lane-op surface (mul/sub/min/max/add) |
| `biquad_bank4` | one DF2T biquad × 4 channels in lanes, fused via `mul_add` | relaxed-SIMD FMA + `replace` + cross-lane state |
| `gain_buf` | scalar in-place gain over a 1024-sample `Vec<f32>` | the block-processing memory loop, per-element bounds checks |
| `gain_buf_simd4` | the same via `Simd.load` / `x.store`, 4 lanes | vectorized buffer access, one bounds check per group |
| `mix04` | 4 saw voices × gain, summed | the DAW summing loop: adds, muls, wrap branches |
| `biquad4` | 4 cascaded DF2T biquads | the canonical IIR workload, ~22 locals |
| `fir16` | 16-tap FIR, unrolled shift register | the convolution shape, ~38 locals |
| `softclip` | cubic waveshaper with clamp branches | nonlinearity + branchy inner loop |
| `wavetable16` | 16-entry table, linear interp | variable-index memory reads per sample |

## Results (2026-08, x86-64 Linux container, wasmtime 45)

```
kernel              q64-dbg      q64-rel         rust rel/rust
mac_f32                1.46         1.43         1.45     1.0x
mac_simd4              0.36         0.30         0.37     0.8x
clip_simd4             0.98         1.07         3.98     0.3x
biquad_bank4           0.80         0.77        15.65     0.05x
gain_buf               3.68         3.67         0.09    39.8x
gain_buf_simd4         0.53         0.68         0.09     7.4x
mix04                  4.14         3.71         3.89     1.0x
biquad4               11.73         7.56         7.66     1.0x
fir16                 25.16        21.21        17.52     1.2x
softclip               3.11         4.33         4.05     1.1x
wavetable16            4.55         3.76         3.02     1.2x
```

ns/sample. q64 = `q64 emit --addr wasm32`, debug and `--release`, run under
the embedded `q64-wasmtime-host` **built ReleaseFast**. Rust = `--release`
with `+simd128`, run under the vendored wasmtime CLI. All checksums match
across languages. Absolute numbers drift up to ~40% between container
sessions (CPU frequency/noise) — compare ratios within one run, never
numbers across runs.

### Finding 1 — a Debug-built host executes guest f32 loops ~100× slower

The first run of this suite reported 60–307× ratios on the bigger kernels.
None of that was q64: the host binary was a default `zig build` (Debug), and
under a **Debug-built** `q64-wasmtime-host` a pure-local f32 guest loop falls
off a cliff the moment more than 16 f32 locals are live — 15 live chains run
1M iterations in ~2.4 ms, 16 chains take ~252 ms (~106×), compounding from
there (`fir16`, ~38 locals, landed at 2.2 µs/sample). f64 hits the same
cliff later (17 locals fine, 25 locals ~800×). Rebuilding the *host* with
`-Doptimize=ReleaseFast` — same source, same `libwasmtime.so` — collapses
every ratio to ~1× (the table above).

This should be impossible — the host's build mode changing the execution
speed of JIT-compiled *guest* code — which is why the isolation is recorded
here. With [`repro/host-f32-pressure.wat`](./repro/host-f32-pressure.wat)
(the q64-emitted 16-chain loop verbatim, wrapped in a WASI `_start`):

- Debug host: ~267 ms; ReleaseSafe / ReleaseFast host: ~8 ms. Reproducible
  A/B/A, identical module bytes, same dynamically-linked `libwasmtime.so`.
- The vendored wasmtime CLI runs it fast at every setting (any opt level,
  even winch); a minimal C embedding against the same `libwasmtime.so` with
  the same config runs it in ~7 ms — the library and the wasm are fine.
- Ruled out: Cranelift opt level (explicitly `SPEED` — no change), compile
  time (a module containing but never calling the function runs in 16 ms),
  memory64 on the config (off — no change), a signal storm (strace shows
  ~400 syscalls total, no fault traffic), stack placement (shifting the
  stack via environment padding — no change).

The microarchitectural mechanism is still open (something about a Debug
host process degrades spill-heavy f32 JIT code in-CPU), but the operational
rule is simple and now enforced: **never benchmark — or ship — a Debug
build of the host.** `run.sh` runs `calibrate.q` (17 live f32 chains) first
and aborts if the probe is slow. Worth an upstream wasmtime issue once the
mechanism is understood.

### Finding 2 — unoptimized q64 is already at parity with release Rust here

With the host fixed, debug-mode q64 codegen — no Binaryen optimization
passes at all — lands at 0.5–1.4× of `--release` Rust across all seven
kernels, meeting Phase A's "within ~1.5×" exit criterion on the spot. Two
honest caveats before celebrating:

- These kernels are register-resident scalar loops, exactly what a
  straightforward expression-tree emitter is good at. The emitter's known
  redundancies (aggregate-result copies, watermark traffic) sit on paths
  these kernels don't exercise; memory-heavy code will show a real gap —
  `wavetable16` (1.4×, the only kernel above parity) already hints at it:
  its per-sample table reads carry bounds checks and arena addressing that
  Rust's optimizer hoists.
- Where q64 *beats* Rust (`mix04` 0.5×, `fir16` 0.8×), part of the edge is
  structural: v0 q64 has no array writes, so its kernels keep state in
  scalars the JIT can register-allocate, while the idiomatic Rust twins use
  small arrays. Same math (checksums match), different memory shape.

Phase A2 (a `--release` mode running `BinaryenModuleOptimize`) is still
worth doing — for code size, for the memory-path redundancies, and for
kernels the suite doesn't cover yet — but the headline is that the gap it
must close is far smaller than assumed.

### Finding 3 — `--release` (phase A2): a net win, with two measured lessons

`q64 emit --release` now runs Binaryen's `-O2` (speed-focused) as an
isolated post-pass. Tuning it against this suite taught two things:

- **Wasm-level inlining is disabled** (`BinaryenSet*InlineMaxSize(0)`).
  With the default pipeline, inlining the hot `pass` function into `main`
  merged the kernel's locals with the timing state, raised register
  pressure in the merged frame, and made the serial kernels ~2× *slower*
  under Cranelift. With inlining off, the rest of `-O2` keeps its wins.
  Cranelift gains little from wasm-level inlining anyway.
- **Branch→`select` if-conversion can pessimize branchy DSP.** `softclip`
  is the one release regression (3.0 → 4.4 ns/sample): `-O2` turns four
  predictable, rarely-taken branches into `select`s (5 vs 1 in the wat),
  which forces both sides to compute every sample and lengthens the
  dependency chain. No clean Binaryen knob exists for it today; recorded
  as a tuning candidate rather than blocking the flag.

Net: release beats or matches debug on six of seven kernels (fir16 −25%,
wavetable16 −17%, and ~20% smaller modules), and `wavetable16` — the
memory-path signal — drops from 1.4× to 1.1× of Rust.

### Finding 4 — the v0 Simd slice works and pays

`mac_simd4` runs ~4× faster than `mac_f32` in q64 — the v0 `Simd<f32, 4>`
slice is real and matches LLVM-vectorized Rust. The lane-wise op surface is
now complete for f32x4 (`add`/`sub`/`mul`/`div`/`min`/`max`,
`neg`/`abs`/`sqrt`; integer lanes keep `add`/`sub`/`mul`/`neg`/`abs`), and
`clip_simd4` shows why explicit lanes beat hoping for autovectorization:
the branch-free min/max clamp compiles straight to `f32x4` ops in q64
(~1.0–1.2 ns/sample) while LLVM declines to vectorize the same math from
the scalar Rust source (~4.0 ns/sample — float min/max NaN semantics block
it) — q64 3–4× ahead on identical checksums.

**Buffers work now too**: `Simd.load(v, i)` / `x.store(v, i)` move four
lanes between a `Simd<f32, 4>` and a `Vec<f32>` with one bounds check per
group, emitted inline (a first cut as `__vec`-style helper functions cost
~2× in call overhead — the per-group call showed up directly in this
kernel, so the emitter builds the check + address at the call site
instead). `gain_buf_simd4` runs 8.9× faster than its scalar twin. The
remaining 7.5× to Rust's auto-vectorized loop is bounds checks per group,
header re-loads, and no unrolling — Rust's `iter_mut` loop pays for none
of those; closing it means hoisting the bounds check out of the loop
(future optimizer work), not changing the surface.

**Cross-function values, lane insert, and fused multiply-add landed as the
third slice.** `Simd<f32, 4>` is now legal as a parameter and return type
(the frame-reclamation stash grew a v128 slot), `v.replace(n, x)` sets one
lane, and `a.mul_add(b, c)` emits the relaxed-SIMD fused madd. The payoff
kernel is `biquad_bank4` — one biquad filtering four channels in lanes,
its DF2T core written as three fused chains: **q64 runs it ~20× faster
than the Rust twin** (0.80 vs 15.65 ns/sample) with **bit-identical
checksums**. The reason is structural, not a compiler race: core wasm has
no scalar FMA, so Rust's `f32::mul_add` lowers to the correctly-rounded
`fmaf` soft-float libcall per lane, while q64's `mul_add` reaches the
hardware FMA through relaxed SIMD — same rounding on FMA hardware, ~20×
the speed. (Relaxed caveat: an engine without hardware FMA may execute
madd unfused, changing low-order bits and this kernel's checksum;
WebKit/Safari also doesn't ship relaxed SIMD yet — a kernel that must run
there should stay with mul/add.) Still missing for DSP: `Simd` in struct
fields, f64x2 (roadmap phase A3).

### Finding 5 — v0 language gaps the kernels had to code around

Hit while writing seven small DSP loops; each is a data point for the
roadmap's language phases:

- **`ref` parameter mode is not implemented** (`ImmutableAssign`) — a
  `stage(x, ref s1, ref s2)` biquad helper can't carry filter state;
  `biquad4` hand-inlines all four stages.
- **Array literals only compile inside `main`** (`UnsupportedExpression` in
  any other function) — `wavetable16` runs its whole kernel in `main`.
- **Array element writes are unsupported** (`a[i] = x`) — no mutable
  buffers; every kernel is scalar-state.
- **No f32 literal suffix** — every f32 constant is written `f32(0.5)`.
- **`out` is a reserved word** (parameter mode) — surprising in audio code,
  where `out` is the natural name for an output sample.
- Multiline expressions parse but produced a pathological result in the
  first `fir16` cut; stepwise accumulation is both idiomatic and safe.

## Layout

```
bench/
├── kernels/*.q          # the q64 side, one self-timing file per kernel
├── baseline-rust/       # the Rust side, one binary, same output protocol
├── repro/               # minimal reproductions for findings (wat)
├── run.sh               # build both, run both, print the table
└── .out/                # build products (gitignored)
```

Adding a kernel: write `kernels/<name>.q` printing the standard bench line,
mirror it in `baseline-rust/src/main.rs`, and keep the math
operation-identical so the checksums stay comparable.
