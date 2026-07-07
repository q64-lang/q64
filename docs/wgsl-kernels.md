# q64 → WGSL compute kernels

Status: design note (2026-07), per `docs/language-analysis-2026-07.md` §3
item 11. Nothing implemented; this pins the shape so the Tensor ladder and
the gfx plans converge instead of forking.

## The bet

The portable GPU story is **WebGPU compute**, because it is the only GPU
API that satisfies the WebKit/iPad floor — and it is native-quality on
desktop through wgpu/Dawn (Vulkan/Metal/D3D12). `stdlib/gfx` already
promises "shaders written in q64, compiled to WGSL, not embedded as
strings"; this note generalizes that from fragment shaders to compute.

## Mechanism: a fourth backend consumer of MIR

- **`@kernel`** marks a function compiled *additionally* to WGSL. Its body
  must sit in the kernel subset: scalar/vector/`Tensor` arithmetic, no
  capabilities, no allocation, no calls outside other `@kernel` fns —
  enforced by the effect lattice exactly like `@differentiable`
  (`GPU001` on violation).
- The WGSL emitter consumes **MIR** — the same backend-neutral tier
  Binaryen consumes. MIR's structured control flow (block/if/loop) maps
  1:1 onto WGSL's; no relooper needed. This is the payoff of the two-tier
  IR discipline: a new target is an emitter, not a compiler.
- Buffers: a `Tensor<f64, [R, C]>` parameter lowers to a WGSL
  `storage` buffer binding + shape constants (f64 needs the
  `shader-f16`-style feature probe — v0 kernels are f32; a `Tensor<f32,…>`
  elem type lands with the Tensor follow-ons).
- Dispatch is a capability: `env.gpu.dispatch(kernel, grid, buffers…)`
  carries `@gpu` (⇒ `@io`), so GPU use is manifest-visible like every
  other resource. The host adapter (browser WebGPU / native wgpu) owns
  queues and readback.

## Sequencing

1. `Tensor<f32, …>` element types (Tensor follow-on already recorded).
2. The kernel subset check on HIR (reuse the `@differentiable` walker).
3. MIR→WGSL emitter for scalar+tensor arithmetic; golden-text tests
   (WGSL is text — the dumper IS the artifact).
4. The `env.gpu` face on the browser adapter first (WebGPU is right
   there); wasmtime host via wgpu-native after.

CPU fallback: a `@kernel` fn is still an ordinary q64 function — the wasm
build runs it unchanged, so kernels are portable by construction and the
GPU path is a pure acceleration.
