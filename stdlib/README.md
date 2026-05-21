# stdlib

The q64 standard library. A qube workspace; one qube per top-level namespace.

> **Status: not yet implemented.** Each namespace folder currently holds a
> README describing its scope. Implementation begins after the `q64`
> compiler is capable enough to compile q64 source end-to-end.

## Layout

| Qube                                          | Surface                                                                            |
|-----------------------------------------------|------------------------------------------------------------------------------------|
| [`math/`](./math)   → `q64.math`              | `Vec`, `Mat`, `Quat`; linear algebra; FFT                                          |
| [`anim/`](./anim)   → `q64.anim`              | `Transform`, `Keyframe`, `Curve`, `Bone`, skinning, IK                             |
| [`ai/`](./ai)       → `q64.ai`                | `Vocab`, `Token[V, Repr]`, `Model[InV, OutV]`, sampling, decoding                  |
| [`net/`](./net)     → `q64.net`               | `Url`, `Net`, `Request`, `Response`, HTTP, WebSocket                               |
| [`audio/`](./audio) → `q64.audio`             | PCM streams, audio I/O, DSP                                                        |
| [`gfx/`](./gfx)     → `q64.gfx`               | Graphics types, GPU bridging                                                       |
| [`video/`](./video) → `q64.video`             | Video frame types, codec interfaces                                                |
| [`fs/`](./fs)       → `q64.fs`                | Filesystem access via the `env.fs` capability                                      |

## Language

Each qube is written in q64 itself. The numeric primitives `Simd`, `Tensor`,
and `DynTensor` are baked into the [`q64/`](../q64) compiler as builtin types
(per [`design/stdlib.md`](https://github.com/q64-lang/design/blob/main/stdlib.md):
"always available, no import needed") — they do not live in this folder.

Host-boundary code (BLAS, WebGPU, WebNN, syscall ABIs) lives in
[`../runtime/<host>/`](../runtime) and is written in the host's language, not in q64.

## Workspace

The top-level `qube.json5` in this folder lists each namespace as a workspace
member. `qube build` from `stdlib/` builds all of them; from any subfolder it
builds just that qube.
