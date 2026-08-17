# bench — DSP kernel benchmarks

Phase A1 of [`docs/audio-roadmap.md`](../docs/audio-roadmap.md): seven audio
microkernels written twice — in q64 (`kernels/*.q`) and in Rust
(`baseline-rust/`) — compiled to wasm32 and timed under the repo's own
toolchain. Until this existed there were zero benchmarks in the repo; every
performance claim was folklore. The point is not the absolute numbers (they
are machine-relative) but the **ratios**, and what they attribute the gap to.

## Run it

```sh
./init.sh                              # vendor/ toolchain
(cd q64 && zig build)                  # the compiler
(cd runtime/wasmtime && zig build)     # the embedded host
rustup target add wasm32-wasip1        # the baseline's target
./bench/run.sh
```

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
| `mix04` | 4 saw voices × gain, summed | the DAW summing loop: adds, muls, wrap branches |
| `biquad4` | 4 cascaded DF2T biquads | the canonical IIR workload, ~22 locals |
| `fir16` | 16-tap FIR, unrolled shift register | the convolution shape, ~38 locals |
| `softclip` | cubic waveshaper with clamp branches | nonlinearity + branchy inner loop |
| `wavetable16` | 16-entry table, linear interp | variable-index memory reads per sample |

## Results (2026-08, x86-64 Linux container, wasmtime 45)

```
kernel            q64 ns/samp   rust ns/samp    ratio
mac_f32                  0.93           1.04     0.9x
mac_simd4                0.23           0.26     0.9x
mix04                  253.00           4.04    62.6x
biquad4                382.02           5.12    74.5x
fir16                 2241.37           7.30   307.0x
softclip                27.84           2.18    12.8x
wavetable16            134.98           2.23    60.5x
```

q64 = `q64 emit --addr wasm32` (debug — there is no release mode yet), run
under the embedded `q64-wasmtime-host`. Rust = `--release` with `+simd128`,
run under the vendored wasmtime CLI. All checksums match across languages.

### Finding 1 — the embedded host has a ~100× f32 register-pressure cliff

The 60–307× ratios are **not** primarily q64 codegen. A pure-local f32 loop
falls off a cliff under `q64-wasmtime-host` the moment more than 16 f32
locals are live: 15 live chains run 1M iterations in ~2.4 ms, 16 chains take
~252 ms (~106×), and it compounds from there (`fir16`, ~38 locals, lands at
2.2 µs/sample). f64 hits the same cliff later (17 locals fine, 25 locals
~800×).

It is an *execution*-side host problem, not a codegen or Cranelift-in-general
problem, isolated by [`repro/host-f32-pressure.wat`](./repro/host-f32-pressure.wat)
— the q64-emitted 16-chain loop verbatim, wrapped in a WASI `_start`:

```sh
wat2wasm bench/repro/host-f32-pressure.wat -o /tmp/shape.wasm
time vendor/wasmtime/bin/wasmtime run /tmp/shape.wasm        # ~0.01 s
time runtime/wasmtime/zig-out/bin/q64-wasmtime-host /tmp/shape.wasm  # ~0.26 s
```

Identical bytes, same wasmtime version: fast under the CLI (at every
opt-level, even under winch), ~100× slow under the C-API embedding. Ruled
out: Cranelift opt level (explicitly setting `SPEED` changes nothing),
compile time (a module that contains but never calls the function runs in
16 ms), the q64 code shape (the CLI runs it fast). Root cause in the
embedding is still open — but any real DSP kernel exceeds 16 live f32
values, so this is the top blocker for trusting q64 numbers under the
embedded host, and it gates Phase A's "within ~1.5× of Rust" exit criterion.

### Finding 2 — parity where the cliff doesn't reach, ~13× where it doesn't

Below the pressure cliff the picture is much better than expected for an
unoptimized compiler: `mac_f32` and `mac_simd4` are at **parity** with
release-mode Rust (both latency-bound on a serial dependency), and
`softclip` (11 locals) shows ~13× — that number is the honest measure of
what Phase A2 (turning on `BinaryenModuleOptimize`) plus the emitter's known
redundancies are worth. Re-attribution of the big-kernel ratios has to wait
until the host cliff is fixed.

### Finding 3 — the v0 Simd slice works and pays

`mac_simd4` runs 4.03× faster than `mac_f32` in q64 (0.23 vs 0.93
ns/sample) — the v0 `Simd<f32, 4>` splat/add/mul/extract slice is real and
matches LLVM-vectorized Rust. The lanes are there; what's missing for DSP is
slice load/store and the rest of the op set (roadmap Phase A3).

### Finding 4 — v0 language gaps the kernels had to code around

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
