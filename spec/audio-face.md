# The audio face — wire format and plugin surface

How real-time audio crosses the guest/host boundary, in both
directions: a q64 program as the **app** (the host provides
`env.audio` — engines, standalone synths, offline render), and a q64
program as the **plugin** (the host calls in — the `--wclap` target
today, native CLAP later). One wire format serves both; the difference
is only who owns the process loop.

This is the first concrete instance of a hand-specced typed-face ABI
(option 1 in `todo.md` §"Host ABI for non-trivial faces") — it drives
the abstraction by example. When a second structured face is specced,
whatever generalizes moves up.

> **Status: v1.** The wire format below is **implemented and
> verified** on the plugin side by the `--wclap` build target
> (`docs/audio-roadmap.md` phase D: `examples/audio-wclap`, loaded in
> the plinken.org reference browser host) and by the browser-delivery
> examples (`examples/audio-web`, `examples/audio-worklet`). The
> declared `AudioPlugin` face (§below) is **specced, not yet in
> sema** — today's `--wclap` consumes the fixed v0 export convention
> it supersedes. The app-direction `Audio` capability face is
> **specced, not yet hosted** — no runtime implements `env.audio`
> yet. When code and this spec disagree, this spec is right.

## Design goals

1. **One wire format, both directions.** Planar `f32`, a block per
   callback, parameters as `id → f64` targets. A DSP graph written
   against `q64.audio` runs unchanged under an `env.audio` host, an
   AudioWorklet export, or a CLAP-family plugin shim.
2. **`@realtime` is load-bearing.** Every operation this spec puts on
   the audio path is statically no-alloc / no-suspend / no-panic
   (`effects.md`). Everything that allocates — activation, parameter
   declaration, buffer negotiation — happens at setup time.
3. **Stable addresses, zero copy.** Audio buffers live in guest
   linear memory as `Vec<f32>`; the boundary handle is the vec
   *header address* (`v.head`). Negotiated once at activation, then
   re-entered every block with no per-block allocation or copy.
4. **Deterministic and greppable.** The layouts below are exact byte
   offsets; a host decoder and `grep '@realtime'` both enumerate the
   contract mechanically.

## Vocabulary

| Word            | Meaning                                                                                  |
|-----------------|-------------------------------------------------------------------------------------------|
| **block**       | One process callback's worth of frames. Size arrives per call, bounded by the activation. |
| **quantum**     | The Web Audio render block — 128 frames. The baseline block size and budget unit.          |
| **activation**  | The setup-time exchange: sample rate + max block size in, buffer addresses out.            |
| **planar**      | One contiguous `f32` run per channel — never interleaved.                                  |
| **target**      | A parameter's host-set value. The guest smooths toward it; it never steps the DSP directly.|
| **`v.head` re-entry** | Re-creating a `Vec<f32>` view from its stored header address `{data, len, cap}` — the boundary handle for guest buffers. |

## The wire format

### Samples

**Planar, non-interleaved `f32`.** One buffer per channel. This is
simultaneously Web Audio's layout, CLAP's `data32` layout, and four
`Simd<f32, 4>` lanes per 16 bytes — the only choice that is zero-copy
against every target and vectorizes without a shuffle.

Interleaved and integer PCM (`PCM<i16>`, …) are file-I/O and codec-edge
concerns with explicit conversions, deferred (roadmap phase E).

### Blocks and budget

Block size is passed **per process call**, never fixed at activation;
activation fixes only the **maximum**. Hosts deliver whatever the
platform hands them (Web Audio: 128). The real-time budget is the
block duration:

| sample rate | block | budget |
|---|---|---|
| 48 kHz | 128 | 2667 µs |
| 48 kHz | 512 | 10667 µs |
| 44.1 kHz | 128 | 2902 µs |

Measured reference: the phase-C voice (saw → biquad → soft clip, with
per-sample parameter smoothing) processes a 128-frame block in ~2 µs
native and ~16 µs under a browser-engine wasm host — two orders of
magnitude inside budget (`bench/README.md`, `examples/audio-wclap`).

### Buffers and ownership

Audio buffers are `Vec<f32>` in guest linear memory. The boundary
handle is the **header address** — the `i64` from `v.head`, pointing
at the 12-byte (wasm32) header `{data: ptr, len, cap}`:

- **Guest-owned (the default, both directions).** The guest allocates
  at setup time (`Vec.new` under no `@realtime` constraint) and hands
  the header address across once. Every block, the other side
  re-enters by header — no re-negotiation, no copy. This is how
  `examples/audio-worklet` persists oscillator/filter state across
  400+ quanta.
- **Host-owned overlay (plugin targets).** When the host owns the
  block buffer (CLAP's `clap_process`), the shim writes a scratch
  header over the host's channel pointer and passes *that* header —
  the guest's `out`-mode `Vec<f32>` writes host memory directly. Same
  handle shape, inverse ownership, still zero copy.

Buffer addresses are **stable across the activation**: a guest must
not grow or reallocate a negotiated buffer while active (growth
reallocates, invalidating the header the other side holds). That
stability is what keeps the per-block path `@realtime`-typed.

### Parameters

`id: u32 → value: f64` **targets**, with **guest-side smoothing**:

- The host (or shim) stores the latest target per id; the guest's
  process loop one-pole-smooths its working value toward the target
  every sample (the `q64.audio` convention, coefficient ≈ 0.003 at
  48 kHz ⇒ ~7 ms time constant). Host automation therefore lands
  click-free with no host-side ramp generation.
- Values **snap at block boundaries** in v1. Sample-offset-accurate
  automation (CLAP carries a `time` field; see the event header
  below) is deferred — the field is already in the layout, so
  adopting it later changes no wire bytes.
- Out-of-range values clamp before they reach the DSP — by the shim
  for shim-owned tables, by `set_param` for guest-declared ones.
- A parameter **declaration** is setup-time data: `{id, name, min,
  max, default, flags}`. It is read once, never on the audio path.

### Events

Events travel as a length-prefixed queue whose entry layout mirrors
the CLAP event header byte-for-byte, so plugin targets translate by
pointer cast rather than re-encoding:

```
offset  size  field
0       u32   size        total entry bytes (header + payload)
4       u32   time        sample offset within the block (v1: ignored, block-snap)
8       u16   space_id    0 = core
10      u16   type
12      u32   flags
16      …     payload     (type-specific)
```

v1 pins two payloads:

- **param-value** (`type = 5`): `param_id: u32 @16`, `value: f64 @40`
  (8-aligned; the intervening note/port/channel/key fields are −1 =
  wildcard).
- **note** (`type = 0` on, `1` off, `2` choke): `note_id: i32 @16`,
  `port_index: i16 @20`, `channel: i16 @22`, `key: i16 @24` (MIDI
  key, 0–127; out-of-range/wildcard keys are ignored),
  `velocity: f64 @32` (8-aligned, 0–1, clamped at the boundary) —
  40 bytes. Semantics: note-on sets the pitch (equal temperament,
  A4 = 440 at key 69) and opens the **gate** at the velocity;
  note-off and choke close it. The gate is a gain *target* like any
  parameter — the guest's smoothing ramp is the attack/release
  envelope, so v1 needs no envelope machinery on either side. That
  describes the mono fallback; a guest that takes note events as
  calls (the optional `note_on`/`note_off` exports, §below) owns
  pitch, envelopes, and polyphony itself — voice allocation is a
  guest concern by design (`examples/audio-poly`, 8 voices).

Raw MIDI pass-through (`type = 10`, CC / pitch bend / aftertouch)
is deferred; the queue and header do not change when it lands.

In the app direction the queue lives in a guest `RingBuffer` region;
in the plugin direction it is walked through the host's accessor
callbacks (CLAP `in_events.size`/`.get` via `call_indirect`).

### Environment invariants

- **Sample rate** is `f64`, delivered at activation, fixed until
  deactivation.
- **Denormals are the guest's problem.** wasm has no FTZ mode; every
  recursive filter state must be denormal-flushed
  (`q64.audio.denormal_flush`) or decaying tails pay the hardware
  denormal penalty.
- **No allocation, suspension, panics, or capability I/O on the audio
  path** — enforced by `@realtime` body checking (`effects.md`
  EFF100/110/112), not convention.

## The app direction — `env.audio`

The capability face a hosting runtime provides (`env.md` capability
table row `env.audio`). Sketch, to be finalized with the first host
implementation (browser glue or `runtime/audio-host`):

```q64
pub face Audio {
    /// Setup: fix the rate, bound the block, register the output
    /// buffers (one Vec<f32> per channel, by header).
    fn activate(self, sample_rate: f64, max_block: i64) -> bool
    /// One block: the host consumes `n` frames from each registered
    /// buffer. Pool-owned buffers only — this is the audio path.
    fn write_pcm(self, n: i64) @realtime
    fn deactivate(self)
}
```

`env.audio.write_pcm` is one of the explicitly `@realtime`-safe
capability operations (`env.md` §realtime exceptions). Device
enumeration, worklet status, and input capture are host-side concerns
that ride the same activation/queue machinery and are specced when the
first host lands.

## The plugin direction — the `AudioPlugin` face

The declared surface a plugin qube implements. Build targets
synthesize the entire container ABI from it — for WCLAP that means the
CLAP entry/factory/descriptor/vtables, `clap.audio-ports`,
`clap.params`, `malloc`, the growable function table, and the process
trampoline, exactly the shim `--wclap` builds today from the interim
convention.

```q64
import q64.audio

pub struct Param {
    id: i64,
    name: str,
    min: f64,
    max: f64,
    default: f64,
}

pub face AudioPlugin {
    /// Setup time. Allocate state, size for the rate. May allocate.
    fn init(self, sample_rate: f64, max_block: i64)
    /// Setup time. The parameter table — read once by the target.
    fn params(self) -> Vec<Param>
    /// A new target for one parameter. Called at block boundaries,
    /// before process. Store the target; smooth in process.
    fn set_param(self, id: i64, value: f64) @realtime
    /// One block into the output buffer. The face is mono-per-buffer;
    /// multi-channel is repeated buffers (planar).
    fn process(self, out io: Vec<f32>, n: i64) @realtime
}
```

Pinned by what the WCLAP target taught:

- **`set_param` stores, `process` smooths.** The split keeps event
  application trivial (a table write) and puts the smoothing where
  the state lives.
- **`params()` allocates freely** — it runs once at plugin init.
  Names, ranges, and defaults flow into the target's native
  declaration (CLAP `clap_param_info`, 1320 bytes, automatable flag).
- **The compiler owns everything else.** Descriptor identity comes
  from the qube manifest (`qube.json5` name/version/vendor), not the
  face; ports/features from manifest metadata. A plugin author writes
  DSP and a parameter table, nothing C-shaped.

### The interim v0 convention (what `--wclap` consumes today)

Until `AudioPlugin` lands in sema, `--wclap` wraps a module exporting:

```
alloc_f32(n: i64) -> i64                                  // state Vec, by v.head
process(st, io, n: i64, p0…pk: f32) -> i64  @realtime     // one block
```

with the shim defining the parameter table and mapping targets to the
positional `f32` params. Four **optional** exports move behavior from
the shim into the guest when present:

```
state_cells() -> i64                          // own state sizing (else 16)
prepare(ref st, sr: f64) -> i64               // at activate; may allocate
note_on(ref st, key: i64, vel: f32) -> i64    // @realtime
note_off(ref st, key: i64) -> i64             // @realtime (also choke)
```

A guest exporting `note_on`/`note_off` receives note events as calls —
polyphony, voice stealing, and envelopes are guest code, and the
target's mono fallback (pitch table + gate) is not emitted. The
resolution happens at wrap time from the export table, so absent
extensions cost nothing. `examples/audio-poly` is the reference user.

Five more optional exports move the **parameter table** into the guest
(all five or none — a partial table is a wrap error):

```
param_count() -> i64
param_info(i: i64, field: i64) -> f64     // 0=id 1=min 2=max 3=default 4=flags
param_name(i: i64, j: i64) -> i64         // byte j of name i; 0 terminates
set_param(ref st, id: i64, v: f64) -> i64 // @realtime; guest clamps + derives
get_param(ref st, id: i64) -> f64
```

When present, the target's parameter extension serves the guest's table
(names copied byte-by-byte — deliberately scalar-only, no string ABI
crosses the boundary), parameter events forward to `set_param`, the
guest owns clamping and derived math (a cutoff parameter computes its
filter coefficients in-guest with `q64.audio.sin2pi`/`cos2pi`), and
`process` takes the **short signature** —
`process(ref st, out io, n) -> i64` — because targets live in guest
state, not positional arguments.

The convention is a strict subset of the face (state = the `self`
struct, positional params = the declared table, the optional exports =
the face's init/set_param split) and is superseded by it; the lowering
from `fit X : AudioPlugin` to the same shim is mechanical.

### Exit criterion hook

`q64 show world` on a plugin qube must eventually show the audio face
as its complete import surface (`docs/audio-roadmap.md` phase D exit
criteria). That requires `AudioPlugin` in sema plus the world
synthesis treating it like any other face — tracked there, not here.

## Pinned vs deferred

| pinned (v1) | deferred |
|---|---|
| planar `f32` | interleaved / integer PCM kinds |
| block size per call, max at activation | — |
| `v.head` header handle, stable addresses | shared-memory / multi-thread buffers |
| params `id → f64`, guest smoothing, block snap | sample-offset automation |
| CLAP-shaped event header, param-value + note on/off/choke | raw MIDI pass-through (CC, pitch bend) |
| polyphony as guest-side voice allocation (notes forwarded as calls) | — |
| one output port, planar channels | multi-port, sidechain |
| `f64` sample rate at activation | rate changes while active |
| — | state save/load, GUI (webview) surface |

## Cross-links

- [`effects.md`](./effects.md) — `@realtime` and its implication set;
  the body checks that enforce this spec's audio-path rules.
- [`env.md`](./env.md) — the capability table (`env.audio`), the
  `@realtime`-safe exception list.
- [`docs/audio-roadmap.md`](../docs/audio-roadmap.md) — phase D
  status; what landed when.
- `examples/audio-worklet`, `examples/audio-wclap` — the two working
  instances of this wire format (guest-owned and host-owned overlay
  respectively), each with an honest conformance check.
