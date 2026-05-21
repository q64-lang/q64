# examples

Sample qubes that exercise the language end-to-end. These double as smoke
tests for the compiler, the stdlib, and the runtime adapters.

> **Status: not yet implemented.** Examples will land as the language
> becomes capable enough to compile them.

## Planned examples

- **`voice-agent/`** — microphone → ASR → LLM → TTS → speaker pipeline,
  the canonical multi-stream demo from
  [`design/example.md`](https://github.com/q64-lang/design/blob/main/example.md).
  Exercises `Signal.<PCM.<f32>>`, `Stream.<Token.<V>>`, vocab translation, and
  `@realtime` effect propagation.
- **`audio-dsp/`** — a small synth + effects chain. Tests `q64.audio`,
  fixed-shape SIMD kernels, and the audio-host runtime adapter.
- **`3d-demo/`** — rigged character rendered with `q64.gfx` and `q64.anim`.
  Tests `Vec`/`Mat`/`Quat`, skinning, and the browser runtime adapter.
- **`http-server/`** — minimal `q64.net` server qube targeting Wasmtime.
  Tests structured concurrency, capability passing via `env`, and the
  Wasmtime runtime adapter.
- **`ml-inference/`** — a small Whisper-shaped model load and run.
  Tests `q64.ai`, the WebGPU/WebNN bridge, and the BLAS host adapter.

Each example is its own qube with a `qube.json5` declaring its dependencies
on stdlib namespaces.
