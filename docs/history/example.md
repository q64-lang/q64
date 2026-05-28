#Example

# q64 — Functions

## Returning a string

```q64
fn greet(): str {
    "hello"
}
```

A function declared with `fn`, return type after `:` (the same `name: Type` separator used for parameters and fields), body as a tail expression (no `return` keyword needed for single-expression bodies). `str` is the borrowed-slice type for static string literals — no allocation, no region required.

## Returning an int

```q64
fn answer(): i64 {
    42
}
```

`i64` is the default integer type. q64 is 64-bit only — `Memory64`, `table64`, `i64` pointers throughout — so the int example uses `i64` rather than a generic `int`. Unsigned siblings (`u64`, `u32`, …) and narrower signed widths (`i32`, `i16`, `i8`) are available; arbitrary-width integers (`u3`, `u24`, …) are an opt-in power feature for bit-level work.

## Returning a float

```q64
fn pi(): f64 {
    3.14159
}
```

`f64` is the default float. `f16` and `f32` are available — `f32` for audio samples and SIMD lanes, `f16` for ML/tensor work — but plain numeric code reaches for `f64`. The literal `3.14159` is `f64` because `14159` after the dot is digits; that distinguishes it from a unit-postfix literal like `48.kHz`.

## Quantities with units

```q64
fn sample_rate(): Hz {
    48.kHz
}
```

```q64
fn headroom(): Db {
    -6.dB
}
```

Units are part of the type, checked at compile time. `48.kHz` reads as integer `48` followed by the unit suffix `kHz`; the resulting value has type `Hz` (the prefix `k` is a scale factor, not a separate type). `-6.dB` has type `Db`. Mixing them — `48.kHz + (-6.dB)` — is a type error.

Suffix casing follows SI: `kHz`, `MHz`, `Hz`, `dB`, `ms`, `µs`, `kg`. Type names are PascalCase descriptors: `Hz`, `Db`, `Seconds`, `Samples`, `Bytes`, `Semitones`, `Cents`.

# q64 — Kinds

`@kind` declares a distinct semantic type that shares a representation with an underlying type but is not interchangeable with it in expressions. Different from `@unit` (which participates in dimensional algebra), kinds tag a value with a domain — audio sample, color, identifier — and force boundary crossings to be explicit and named. Zero runtime cost; the distinction lives only at type-check time.

## Audio samples (PCM)

```q64
@kind PCM[F]   // parameterized by underlying numeric representation

type Pcm16  = PCM[i16]    // CD-quality integer
type Pcm24  = PCM[i32]    // packed 24-bit in i32
type PcmF32 = PCM[f32]    // float bus default: -1.0..1.0 = 0 dBFS
type PcmF64 = PCM[f64]    // mastering / precision internal

fn silent_block(): [PCM[f32]; 4096] {
    [0.0.pcm; 4096]
}
```

`PCM[i16]` and `PCM[f32]` are distinct types. Conversion is an explicit named operation (`.toF32()`, `.toI16()`); the type system rejects accidentally mixing formats in a signal chain.

## Colors

Two orthogonal axes show up in every pixel: the **color space** (the meaning of the numbers — sRGB / Linear / Display P3 / Rec.2020) and the **representation** (the storage — `u8`, `u10`, `f16`, `f32`). The coordinate model (RGB / HSV / Lab) is a third dimension layered on top.

```q64
// color spaces — zero-sized marker kinds
@kind ColorSpace
type sRGB       = ColorSpace
type Linear     = ColorSpace
type DisplayP3  = ColorSpace
type Rec709     = ColorSpace
type Rec2020    = ColorSpace
type AcesCg     = ColorSpace

// alpha conventions
@kind AlphaKind
type Straight = AlphaKind
type Premul   = AlphaKind

// color types — parameterized by space and representation
@kind Rgb[Space, Repr]              // tristimulus, Cartesian
@kind Hsv[Space, Repr]              // tristimulus, cylindrical (hue-based)
@kind Lab[Repr]                     // CIE perceptual; color space implicit
@kind Rgba[Space, Repr, Alpha]      // RGB + alpha convention
```

`Rgb` and `Hsv` are siblings, not alternatives — RGB for storage, display, and linear-domain math (filtering, blur, mixing); HSV for user-facing hue/saturation operations and color pickers; Lab/OKLab for perceptual operations (Δ-E, perceptually even gradients, contrast). Conversions between them are named.

```q64
fn load_jpeg(path: str): Image[Rgb[sRGB, u8]]

fn to_linear(img: Image[Rgb[sRGB, u8]]):
             Image[Rgb[Linear, f32]]

fn blend(a: Rgba[Linear, f32, Premul],
         b: Rgba[Linear, f32, Premul]):
             Rgba[Linear, f32, Premul]
```

The type system catches the standard graphics bugs: blending in sRGB instead of linear, mixing Display P3 and sRGB on the same canvas, swapping straight and premultiplied alpha, applying RGB ops to a YCbCr buffer.

## Video frames

```q64
// video color standards (transfer function + matrix bundled)
@kind VideoStandard
type BT601     = VideoStandard
type BT709     = VideoStandard
type BT2020    = VideoStandard
type BT2020Pq  = VideoStandard   // HDR10 (PQ transfer)
type BT2020Hlg = VideoStandard   // broadcast HDR (HLG transfer)

// chroma subsampling
@kind ChromaSampling
type Sub444 = ChromaSampling
type Sub422 = ChromaSampling
type Sub420 = ChromaSampling

// video pixel and frame
@kind YCbCr[Standard, Repr]
@kind Frame[Pixel, Subsampling, W: i64, H: i64]

type Hd1080p10 = Frame[YCbCr[BT709,    u10], Sub420, 1920, 1080]
type Uhd4kHdr  = Frame[YCbCr[BT2020Pq, u10], Sub420, 3840, 2160]
type MasterF16 = Frame[Rgb[Linear, f16],     Sub444, 1920, 1080]

fn decode_h264(stream: Bytes): Stream[Hd1080p10]

fn tonemap(hdr: Frame[Rgb[Linear, f16], Sub444, W, H]):
                Frame[Rgb[sRGB,   u8 ], Sub444, W, H]
```

Resolution, color standard, transfer function, and chroma subsampling all live in the type. Encoder and decoder signatures match by name; a pipeline that mixes BT.709 SDR with BT.2020 HDR fails to compile.

## AI tokens

```q64
@kind Vocab    // zero-sized marker — identifies a tokenizer
type LlamaVocab   = Vocab
type WhisperVocab = Vocab
type EncodecVocab = Vocab    // audio codec tokens

@kind Token[V: Vocab, Repr]
type LlamaToken   = Token[LlamaVocab,   u32]
type WhisperToken = Token[WhisperVocab, u32]
type EncodecToken = Token[EncodecVocab, u16]
```

Tokens are not interchangeable across tokenizers. `Token[LlamaVocab]` and `Token[WhisperVocab]` are distinct types — converting between vocabularies is an explicit named operation (`translate(WhisperVocab, LlamaVocab)`), not a silent reinterpretation. Same bug class as `PCM[i16]` vs `PCM[f32]`.

## Composing kinds through streams

`Stream[T]`, `Signal[T]`, and `Event[T]` are language types, not stdlib types — the compiler sees the dataflow graph statically. Kinds plug into them as the element type, so a real-time voice agent (microphone → ASR → LLM → TTS → speaker) is one pipeline crossing audio Signals, discrete Events, and token Streams without leaving the language's dataflow vocabulary:

```q64
stage voice_agent(
    mic: Signal[PCM[f32]],
    llm: Model[LlamaVocab, LlamaVocab],
) -> Signal[PCM[f32]] {
    mic
        |> vad()                       // Signal[PCM]         -> Event[VoiceSegment]
        |> asr(WhisperModel)           // Event[VoiceSegment] -> Stream[WhisperToken]
        |> translate(WhisperVocab, LlamaVocab)
                                       // Stream[WhisperToken]-> Stream[LlamaToken]
        |> complete(llm)               // Stream[LlamaToken]  -> Stream[LlamaToken]
        |> tts(KokoroModel)            // Stream[LlamaToken]  -> Signal[PCM[f32]]
}
```

The compiler sees the whole graph: adjacent stages fuse where possible, vocab mismatch (forgetting `translate(...)`) is a compile error, and effect propagation catches "TTS stage isn't `@realtime`-safe, so this graph can't drive a low-latency audio sink" at compile time rather than as a glitch in production.

# q64 — I/O

## Fetching JSON (long form, explicit error)

```q64
let (obj, err) = env.net.get("https://q64.dev/test/data/obj.json").json()
if let e = err {
    env.err("request failed: {e}")
    return
}
// obj is non-null here by flow typing
```

The HTTP round-trip suspends the task transparently — no `async`/`await` keyword. `env.net` is the network capability, passed explicitly via `env`; there is no ambient global network. `.json()` returns a `Result[Json, IoError]`; destructuring it into `(obj, err)` is sugar over the mutual-exclusion invariant — exactly one of the two is set.

After `if let e = err { return }`, the compiler flow-types `err` as `None` on the fall-through path, which narrows `obj` from `Json?` to `Json` automatically.

## Short forms

The `?` operator propagates the error to the caller; `match` gives full control:

```q64
// shorthand: propagate on error, bind on success
let obj = env.net.get("https://q64.dev/test/data/obj.json").json()?

// full control: pattern match
match env.net.get("https://q64.dev/test/data/obj.json").json() {
    Ok(obj) -> render(obj),
    Err(e)  -> log.warn("fetch failed: {e}"),
}
```

Three styles, same underlying `Result[T, E]`. Pick based on how much the error path needs to look like code at the call site.

## Typed deserialization

The return-type binding drives the parser via `FromJson`. `@derive(FromJson)` generates the deserializer at comptime — no runtime reflection.

```q64
@derive(FromJson)
struct User {
    name: str,
    age:  i64,
}

let (user: User, err) = env.net.get("https://q64.dev/test/data/users/1.json").json()
if let e = err { return e }
```

The destructure pattern carries the same `FromJson` machinery — type annotation on the bound name, parsing happens during `.json()`, errors land in `err`.

## Reading a file

```q64
let (bytes, err) = env.fs.read("data/config.json")
if let e = err { return e }
let (cfg: Config, err) = bytes.json()
if let e = err { return e }
```

`env.fs` is the filesystem capability. The same `.json()` decoder works on any `Bytes` source — network, file, or in-memory buffer. When chaining multiple fallible operations, the long form gets verbose; that's when `?` earns its keep:

```q64
let cfg: Config = env.fs.read("data/config.json")?.json()?
```

## URL templates

```q64
let userId = 42
let host   = "q64.dev"
let url    = "https://{host}/test/data/users/{userId}.json"

let (user: User, err) = env.net.get(url).json()
if let e = err { return e }
```

q64 string literals support `{expr}` interpolation with full type-checked expressions inside. Works in URLs, log messages, error text — any string literal. Numbers, structs with `ToString`, and strings interpolate directly; richer values use `"{value:format}"` style format specifiers.

## Typed URLs

For compile-time validation, prefix the literal with `url`:

```q64
let endpoint: Url = url"https://q64.dev/test/data/users/{userId}.json"
let (user: User, err) = env.net.get(endpoint).json()
```

`Url` is a distinct kind from `str`. The `url"..."` prefix parses and validates at comptime — invalid characters, missing scheme, malformed host become compile errors. Interpolated values are percent-encoded automatically, so URL injection from a forgotten encoder is not possible.

`env.net.get` is typed against `Url`, so passing a bare `str` requires explicit `Url.parse(s)?` — making the unchecked path visible at the call site.

# q64 — CLI basics

## Hello world

```q64
fn main(env: Env) {
    env.out("Hello World")
}
```

`env.out` writes to stdout with a newline. The `env` capability is passed explicitly — no ambient stdout. `env.err` is the stderr equivalent; `env.out.write(...)` is the no-newline form for prompts.

## Running it

`q64 source.q` compiles to Wasm in memory and runs it (equivalent to `q64 run source.q`). The `.wasm` artifact is written to disk only with `q64 build source.q`. Compile diagnostics go to stderr before the program runs, so `q64 script.q | grep foo` works cleanly.

## Shebang scripts

```q64
#!/usr/bin/env q64
fn main(env: Env) {
    env.out("Hello World")
}
```

`chmod +x` and run directly.

## Exit codes

```q64
env.exit(2, "usage: q64 build <file>")   // stderr, exit 2
env.exit(0)                               // clean exit, no output
```

|Path                     |Exit code        |
|-------------------------|-----------------|
|`return` or fall off main|0                |
|`env.exit(N)`            |N                |
|`panic!(...)`            |1                |
|Error propagated to main |`error.code ?? 1`|
|Internal tool error (ICE)|70               |

`env.exit` runs structured cleanup (defers, scoped allocators, flush stdout/stderr) before terminating. SIGPIPE on stdout is a clean exit, not a panic.

## Structured JSON exit

Every `q64` subcommand accepts `--json`. User programs can emit the same envelope shape:

```q64
fn main(env: Env) {
    env.exit(2, {
        diagnostics: [
            {
                code: "NAM003",
                message: "unknown identifier",
                line: 3,
                repair: { id: "declare-missing-symbol" },
            },
        ],
    })
}
```

In `--json` mode this writes to stderr:

```json
{
  "ok": false,
  "diagnostics": [
    {
      "code": "NAM003",
      "message": "unknown identifier",
      "line": 3,
      "repair": { "id": "declare-missing-symbol" }
    }
  ]
}
```

`ok: false` is added by the runtime from the non-zero exit code — the program never repeats it. In default text mode, the same call site renders a formatted error.

## Internal tool errors (ICEs)

When the toolchain itself crashes (formatter, compiler, etc.), the envelope uses a distinct shape so an agent knows not to edit user code:

```json
{
  "ok": false,
  "diagnostics": [
    {
      "code": "Q9001",
      "severity": "internal",
      "kind": "ice",
      "message": "formatter crashed: stack overflow in normalize_decl",
      "location": { "file": "src/foo.q", "line": 142, "col": 8 },
      "context": {
        "tool": "q64 fmt",
        "version": "0.7.2",
        "build": "abc123f",
        "platform": "wasm-wasi-x86_64"
      },
      "trace": ["normalize_decl decl.q:88", "normalize_stmt stmt.q:42"],
      "repair": {
        "id": "report-upstream",
        "safety": "n/a",
        "report_url": "https://q64.dev/ice?code=Q9001&v=0.7.2"
      }
    }
  ]
}
```

Three converging signals tell an agent not to touch user code:

- `Q9xxx` code range reserved for ICEs
- `severity: "internal"` (distinct from `"error"`)
- `repair.id: "report-upstream"` with `safety: "n/a"`

Exit code 70 (sysexits `EX_SOFTWARE`). The crashed tool leaves the user’s file untouched — atomic write-on-success only.