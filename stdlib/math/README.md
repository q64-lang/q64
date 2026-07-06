# stdlib/math → `q64.math`

Scalar floating-point math for q64.

> **Status: scalar transcendentals landed** (`exp`, `sin`, `cos`, `tanh`) on
> top of the compiler's hardware-primitive methods. Vectors, matrices,
> quaternions, linear algebra, and FFT are still planned (see below).

## The design split

The dividing line is **whether a function is a single Wasm instruction**:

- **Hardware primitives** — `abs`, `sqrt`, `floor`, `ceil`, `trunc`, `round`
  (Wasm `nearest`). Each is one Wasm opcode. The compiler already exposes them
  as f64 methods (`x.sqrt()`, `x.floor()`, `x.nearest()`; see
  [`q64/src/ir/ops.zig`](../../q64/src/ir/ops.zig) `UnKind` and their lowering
  in [`q64/src/codegen/emit.zig`](../../q64/src/codegen/emit.zig)). This qube
  only **re-exports** them as free functions so a caller has one `q64.math.*`
  surface.
- **Transcendentals** — `exp`, `sin`, `cos`, `tanh`. There is no Wasm opcode
  for these; they are software (range reduction + a Horner polynomial), i.e.
  ordinary f64 arithmetic. They live **here, in pure q64** — building this qube
  needs no codegen change.

The rule to keep: *Wasm opcode → compiler intrinsic; needs software → stdlib
q64.* Do not add a transcendental to the compiler, and do not reimplement a
hardware op in q64.

## Surface (today)

| Function | Kind | Notes |
|---|---|---|
| `abs`, `sqrt`, `floor`, `ceil`, `trunc`, `round` | primitive | one Wasm instruction each; `round` is half-to-even |
| `exp` | transcendental | range reduce `x = k·ln2 + r`, poly on `r`, scale by `2^k` |
| `sin`, `cos` | transcendental | fold to `[-π/2, π/2]`, 6-term odd Taylor |
| `tanh` | transcendental | `(e^{2x}−1)/(e^{2x}+1)`, clamped past ±20 |

Accuracy target ≈ 1e-9 over audio-DSP argument ranges (waveform phase, a diode
exponent, a soft-clip). Not a libm replacement.

## Build

```sh
qube build --component      # → target/…/q64.math.{wasm,component.wasm}
```

## Surface (planned)

- **Vectors and matrices**: `Vec2`, `Vec3`, `Vec4`, `Mat3`, `Mat4`,
  parameterized by element type and unit-of-measure where applicable.
- **Quaternions**: `Quat<T>` as a distinct kind from `Vec4`; Hamilton
  product, conjugate, slerp.
- **Linear algebra**: `matmul`, `dot`, `cross`, `transpose`, `inverse`,
  `norm`, decompositions.
- **FFT**: forward, inverse, real-to-complex, complex-to-real.
- **Elementwise / broadcasting**: built on top of the `Tensor` builtin type.
- **More scalar transcendentals** (`ln`, `pow`, `atan2`, …) and their **f32**
  variants — added when a consumer pulls them.

Small fixed-shape operations (Mat4 multiply, Quat slerp, Vec3 normalize)
dispatch to hand-tuned Wasm SIMD kernels at comptime. Large-shape operations
delegate to host BLAS / WebGPU / WebNN via the runtime adapter — an explicit
boundary crossing, not an implicit one.
