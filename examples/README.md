# examples

Sample qubes that exercise the language end-to-end. These double as smoke
tests for the compiler, the stdlib, and the runtime adapters.

> **Status: not yet implemented.** Examples will land as the language
> becomes capable enough to compile them.

## Planned examples

- **`voice-agent/`** — microphone → ASR → LLM → TTS → speaker pipeline,
  the canonical multi-stream demo from
  [`design/example.md`](https://github.com/q64-lang/design/blob/main/example.md).
  Exercises `Signal<PCM<f32>>`, `Stream<Token<V>>`, vocab translation, and
  `@realtime` effect propagation.
- **`audio-dsp/`** *(first slice exists)* — a small synth voice: `q64.audio`'s
  saw oscillator → DF2T lowpass → soft clipper, rendered offline into a
  caller-owned buffer (`qube run --addr wasm32` from the folder prints the
  render's energy/peak). The SIMD-kernel and audio-host-adapter halves are
  still planned.
- **`3d-demo/`** — rigged character rendered with `q64.gfx` and `q64.anim`.
  Tests `Vec`/`Mat`/`Quat`, skinning, and the browser runtime adapter.
- **`http-server/`** — minimal `q64.net` server qube targeting Wasmtime.
  Tests structured concurrency, capability passing via `env`, and the
  Wasmtime runtime adapter.
- **`ml-inference/`** — a small Whisper-shaped model load and run.
  Tests `q64.ai`, the WebGPU/WebNN bridge, and the BLAS host adapter.

Each example is its own qube with a `qube.json5` declaring its dependencies
on stdlib namespaces.

## Component / RPC verification slices

These small examples are the verification ladder for the Component Model and
RPC spec (`spec/modules.md`, `spec/env.md`, `spec/rpc.md`). They reuse the
hello shape so they can be validated as the toolchain becomes capable of
component emission.

- **`hello-component/`** — the hello program emitted as a component targeting
  `wasi:cli/command` (`@stdout` → `wasi:cli/stdout`). Proves core-module
  embedding and one capability-import lift. *(Slice A.)*
- **`hello-component-http/`** — an `@http_handler` exporting
  `wasi:http/handler` (the WASIp3 unified handler); the qubepods-shaped
  endpoint. *(Slice B.)*
- **`rpc-server/`** + **`rpc-client/`** — the server serves its world over
  wRPC; the client imports it and calls `greet`, the call carrying `@wire`.
  *(Slice C.)*
