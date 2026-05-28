# q64 — Standard Library

Sketch of how the standard library is organized and what lives where. Not the full API surface — design intent and the major modules. API specifics open to refinement.

## Layered architecture

Three layers, smallest at the bottom:

1. **Numeric primitives** — `Simd[T, N]`, `Tensor[T, Shape]`, `DynTensor[T]`. Core types; always available, no import needed.
2. **`q64.math`** — `Vec`, `Mat`, `Quat` for 3D; linear algebra (matmul, inverse, decompositions); elementwise ufuncs; reductions; FFT.
3. **`q64.anim`** — `Transform`, `Keyframe`, `Curve`, `Bone`, skinning, IK helpers. Built on `q64.math`.
4. **`q64.ai`** — `Vocab`, `Token[V, Repr]`, `Model[InVocab, OutVocab]`, sampling, decoding. Token-stream primitives for LLMs and multimodal models.
5. **`q64.net`** — `Url`, `Net`, `Request`, `Response`, HTTP convenience methods, WebSocket, streaming bodies. Accessed via the `env.net` capability.

Higher layers are namespaced rather than auto-imported. `q64.audio`, `q64.gfx`, `q64.video`, `q64.fs` follow the same pattern.

## Numeric primitives

```q64
@kind Simd[T, N: i64]                // hardware-mapped SIMD lanes
@kind Tensor[T, Shape: [i64]]        // static-shape tensor
@kind DynTensor[T]                   // shape carried at runtime
```

Shape lives in the type when known at compile time. `DynTensor` is the explicit escape hatch for runtime-shaped data (model loading, unknown-size buffers, etc.).

Elementwise arithmetic compiles to fused Wasm 3.0 SIMD loops via comptime. Broadcasting compatibility is a comptime predicate — shape mismatches produce compile errors with the shapes printed, not runtime crashes.

No external BLAS dependency. Small fixed-shape ops (Mat4 multiply, Quat slerp, Vec3 normalize) use hand-tuned Wasm SIMD kernels; large-scale linear algebra and ML inference delegate to host BLAS, WebGPU, or WebNN through the runtime adapter as an explicit boundary crossing.

## q64.math

### Vectors and matrices

```q64
type Vec2[T] = Tensor[T, [2]]
type Vec3[T] = Tensor[T, [3]]
type Vec4[T] = Tensor[T, [4]]
type Mat3[T] = Tensor[T, [3, 3]]
type Mat4[T] = Tensor[T, [4, 4]]
```

Units flow through the math:

```q64
type Position = Vec3[f32, Meters]
type Velocity = Vec3[f32, Meters / Seconds]
type AngVel   = Vec3[f32, Radians / Seconds]

fn step(p: Position, v: Velocity, dt: Seconds): Position {
    p + v * dt    // Meters + (Meters/Seconds) * Seconds = Meters
}
```

### Quaternions

Distinct kind from `Vec4`. Same storage (4 floats), different algebra — Hamilton product, conjugate, slerp on the unit sphere; not dot/cross/elementwise. Treating one as the other is a compile error.

```q64
@kind Quat[T] : Tensor[T, [4]]

fn slerp(a: Quat[f32], b: Quat[f32], t: f32): Quat[f32]
fn quat_from_axis_angle(axis: Vec3[f32], angle: Radians): Quat[f32]
fn quat_to_mat3(q: Quat[f32]): Mat3[f32]
```

### Linear algebra

```q64
fn matmul[A, B, C](a: Tensor[T, [A, B]], b: Tensor[T, [B, C]]):
                   Tensor[T, [A, C]]
fn dot[N]         (a: Tensor[T, [N]], b: Tensor[T, [N]]): T
fn cross          (a: Vec3[f32], b: Vec3[f32]): Vec3[f32]
fn transpose[A, B](m: Tensor[T, [A, B]]): Tensor[T, [B, A]]
fn inverse        (m: Mat4[f32]): Mat4[f32]?
fn norm[Shape]    (t: Tensor[T, Shape]): T
```

Small fixed shapes dispatch to hand-tuned SIMD kernels at comptime; larger shapes use generic implementations or route through the host adapter.

## q64.anim

### Transforms

```q64
struct Transform {
    rotation:    Quat[f32],
    translation: Vec3[f32, Meters],
}

struct AffineTransform {
    rotation:    Quat[f32],
    translation: Vec3[f32, Meters],
    scale:       Vec3[f32],
}
```

`Transform` is rigid (no scale). `AffineTransform` adds non-uniform scale — kept separate so skinning code on rigid bones doesn't branch on whether scale is present.

### Keyframes and curves

```q64
struct Keyframe[T] {
    time:  Seconds,
    value: T,
}

@kind Curve[T]    // ordered keyframes + interpolation policy

type RotationCurve    = Curve[Quat[f32]]
type TranslationCurve = Curve[Vec3[f32, Meters]]
type ScalarCurve      = Curve[f32]

fn sample[T](c: Curve[T], at: Seconds): T
```

The interpolation type comes from `T`'s algebra — `Curve[Quat]` slerps, `Curve[Vec3]` lerps, `Curve[f32]` is scalar. One `Curve` shape across the board.

### Skeleton, skinning, IK

Standard shapes: `Skeleton` (rooted hierarchy of `Bone`), `AnimClip` (named tracks of `Curve[Transform]`), `pose_skeleton(skel, clip, t) -> [Mat4[f32]]`. Skinning matrices, blend trees, retargeting, and basic IK solvers (two-bone, FABRIK) live here. To be detailed.

### Stream integration

In a stream-first language, animation is a graph node consuming a clock signal and producing transform streams:

```q64
stage animate(
    clock: Signal[Seconds],
    clip:  AnimClip,
    skel:  Skeleton,
) -> Signal[[Mat4[f32]]] {
    clock.map(|t| pose_skeleton(skel, clip, t))
}
```

The stream runtime handles scheduling, fusion, and feeding the output into downstream stages (GPU upload, IK pass, render).

## q64.ai

Token, vocabulary, and model primitives for language and multimodal AI workloads.

### Vocab and Token

```q64
@kind Vocab    // zero-sized marker — identifies a tokenizer

type Gpt4Vocab    = Vocab    // ~100k tokens
type LlamaVocab   = Vocab
type WhisperVocab = Vocab    // ASR tokens
type EncodecVocab = Vocab    // audio codec tokens (SoundStream/Encodec)
type ViTVocab     = Vocab    // vision transformer patches

@kind Token[V: Vocab, Repr]   // vocabulary identity + storage width

type GPT4Token    = Token[Gpt4Vocab,    u32]
type LlamaToken   = Token[LlamaVocab,   u32]
type WhisperToken = Token[WhisperVocab, u32]
type EncodecToken = Token[EncodecVocab, u16]
```

Tokens are not interchangeable across vocabularies. `Token[Gpt4Vocab]` and `Token[LlamaVocab]` are distinct types; vocab-to-vocab crossing is an explicit named operation (`translate(WhisperVocab, LlamaVocab)`), not a silent reinterpretation. Same bug class as `PCM[i16]` vs `PCM[f32]`.

### Models and inference

```q64
@kind Model[InVocab, OutVocab]   // model parameterized by input/output vocabs

type LlamaModel   = Model[LlamaVocab,   LlamaVocab]
type WhisperModel = Model[Audio,        WhisperVocab]    // audio in, tokens out
type KokoroModel  = Model[LlamaVocab,   Audio]           // tokens in, audio out

fn tokenize(text: str, v: Vocab): [Token[v]]
fn decode[V](toks: Stream[Token[V]], v: V): Stream[str]

stage complete[V](
    model:  Model[V, V],
    prompt: [Token[V]],
) -> Stream[Token[V]] {
    // autoregressive generation; one token per tick
}
```

Models carry their input and output vocabularies in the type. A pipeline mismatch — feeding `Stream[Gpt4Token]` into a Llama decoder — fails at compile time, not at the end of a 30-second inference run.

### Sampling and decoding

```q64
struct SamplingConfig {
    temperature: f32,
    top_k:       u32?,
    top_p:       f32?,
    seed:        u64?,
}

fn sample[V](logits: Tensor[f32, [V.size]], cfg: SamplingConfig): Token[V]
```

Logprobs and per-token metadata are available through a parallel `Stream[(Token[V], LogProbs)]` shape for use cases that need them (speculative decoding, beam search, constrained generation).

## Streams, signals, events in practice

Three dataflow types, many domains. Same vocabulary, same compiler analysis, same effect propagation.

| Domain          | Dataflow                       | Element kind                          |
|-----------------|--------------------------------|---------------------------------------|
| Audio playback  | `Signal[PCM[f32]]`             | continuous samples                    |
| Microphone      | `Signal[PCM[f32]]`             | continuous samples                    |
| MIDI input      | `Event[MidiMessage]`           | discrete events                       |
| UI clicks       | `Event[Point]`                 | discrete events                       |
| Keyboard        | `Event[KeyCode]`               | discrete events                       |
| LLM output      | `Stream[Token[LlamaVocab]]`    | autoregressive sequence               |
| ASR             | `Stream[Token[WhisperVocab]]`  | transcription tokens                  |
| Video frames    | `Signal[Frame[...]]`           | clock-driven                          |
| IMU sensor      | `Signal[Vec3[f32, m/s²]]`      | continuous                            |
| GPS             | `Event[Vec2[f64, Degrees]]`    | sparse fixes                          |
| WebSocket       | `Stream[Bytes]`                | discrete, ordered                     |
| File read       | `Stream[Bytes]`                | discrete, ordered, terminating        |

One vocabulary instead of three (no separate "AsyncIterator" for LLMs, "AudioBus" for samples, "EventEmitter" for UI). A voice agent is microphone → ASR → LLM → TTS → speaker — a single pipeline crossing Signal → Event → Stream → Stream → Signal. Distinct vocabularies would mean glue code at every boundary; the unified one means the same `|>` operator everywhere and one runtime fuses the whole graph.

## q64.net

HTTP, WebSocket, and URL primitives. The network capability is `env.net` of type `Net`.

### Url

```q64
@kind Url    // parsed, validated; components available as fields

let u: Url = url"https://q64.dev/test/data/obj.json"           // comptime-validated literal
let u: Url = url"https://{host}/users/{id}.json"               // interpolation; values percent-encoded
let u: Url = Url.parse("https://q64.dev/...")?                 // runtime parse, fallible

u.scheme     // "https"
u.host       // "q64.dev"
u.port       // 443? (inferred from scheme if absent)
u.path       // "/test/data/obj.json"
u.query      // Map[str, str]
u.fragment   // ""?
```

The `url"..."` prefix performs the parse at comptime — invalid characters, missing scheme, malformed host become compile errors. Interpolated values are percent-encoded automatically, so URL injection from a forgotten encoder is not possible. `Url.parse` is the runtime entry point for URLs that arrive as strings (config, user input).

### Net and requests

```q64
@kind Net   // network capability

fn (n: Net) get   (u: Url): Response
fn (n: Net) post  (u: Url, body: Bytes): Response
fn (n: Net) put   (u: Url, body: Bytes): Response
fn (n: Net) delete(u: Url): Response
fn (n: Net) request(req: Request): Response   // full control

enum Method { Get, Post, Put, Delete, Patch, Head, Options }

@derive(Builder)
struct Request {
    url:     Url,
    method:  Method = Get,
    headers: Headers = Headers.empty(),
    body:    Bytes = Bytes.empty(),
    timeout: Seconds? = none,
}

@kind Response
fn (r: Response) status (): u16
fn (r: Response) headers(): Headers
fn (r: Response) bytes  (): Bytes
fn (r: Response) text   (): str
fn (r: Response) json[T: FromJson]() : T       // typed parse
fn (r: Response) json   () : Json              // untyped sum
fn (r: Response) stream (): Stream[Bytes]      // body as chunk stream
```

The convenience methods (`get`, `post`, ...) cover the common case. `request(...)` takes the full `Request` struct for custom headers, methods, timeouts.

Fallible methods (`.json()`, `.text()`, `.bytes()`) return `Result[T, IoError]`. The two `.json()` overloads are distinguished by binding site: typed via the return-type annotation, untyped without.

### Streaming responses

```q64
let body: Stream[Bytes] = env.net.get(big_url).stream()

body
    |> for_each(|chunk| process(chunk))
```

For large responses (file downloads, server-sent events, model weights) the body is a `Stream[Bytes]` rather than a buffered `Bytes`. Backpressure flows back through the TCP receive window, so a slow consumer naturally slows the producer.

### WebSockets

```q64
let socket = env.net.ws_connect(url"wss://api.q64.dev/live")?

scope {
    spawn {
        loop {
            let msg = socket.recv()
            handle(msg)
        }
    }

    spawn {
        socket.send(json_msg)
    }
}
// socket closes automatically on scope exit
```

A WebSocket exposes a bidirectional `Stream[WsMessage]` pair (`send` + `recv`). Lifetime is scope-bound; closure happens automatically when the scope exits.

### Effects

All network operations carry `@io @network` effects. A `@realtime` stage cannot call them; a `@pure` function cannot call them. The package registry surfaces network usage per qube, so `qube add some_package` discloses whether the dependency does network I/O before installation.
