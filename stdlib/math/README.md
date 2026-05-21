# stdlib/math → `q64.math`

Vectors, matrices, quaternions, linear algebra, and FFT.

> **Status: not yet implemented.**

## Surface (planned)

- **Vectors and matrices**: `Vec2`, `Vec3`, `Vec4`, `Mat3`, `Mat4`,
  parameterized by element type and unit-of-measure where applicable.
- **Quaternions**: `Quat[T]` as a distinct kind from `Vec4`; Hamilton
  product, conjugate, slerp.
- **Linear algebra**: `matmul`, `dot`, `cross`, `transpose`, `inverse`,
  `norm`, decompositions.
- **FFT**: forward, inverse, real-to-complex, complex-to-real.
- **Elementwise / broadcasting**: built on top of the `Tensor` builtin type.

Small fixed-shape operations (Mat4 multiply, Quat slerp, Vec3 normalize)
dispatch to hand-tuned Wasm SIMD kernels at comptime. Large-shape operations
delegate to host BLAS / WebGPU / WebNN via the runtime adapter — an explicit
boundary crossing, not an implicit one.
