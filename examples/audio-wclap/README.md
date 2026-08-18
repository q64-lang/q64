# audio-wclap — the q64 voice as a WCLAP plugin

The `examples/audio-worklet` synth voice wrapped into a **WCLAP** plugin
(CLAP-as-wasm): one wasm module a WCLAP browser host loads directly, with
no JS glue shipped alongside. This is roadmap phase D3's first rung
(`docs/audio-roadmap.md`).

## Build

From the repo root (after `./init.sh`):

```sh
q64/zig-out/bin/q64 emit examples/audio-worklet/src/lib.q \
  examples/audio-wclap/voice.wclap.wasm \
  --addr wasm32 --module q64.audio=$PWD/stdlib/audio/src/lib.q \
  --release --wclap
```

`--wclap` is a post-pass (`q64/src/codegen/wclap.zig`, same shape as
`--asyncify`/`--release`): it reads the emitted core back into Binaryen
and synthesizes the CLAP shim around it —

- `clap_entry` — an exported immutable i32 global holding the address of
  the `clap_plugin_entry` struct in linear memory;
- an exported **growable** `__indirect_function_table` carrying the shim
  callbacks (slot 0 stays null; hosts grow the table to install their own
  trampolines, and a capped table fails at load);
- `malloc`/`free` — hosts allocate id strings, port info, and the
  `clap_process` tree *inside plugin memory* at setup time;
- the factory/descriptor/plugin vtables and the `clap.audio-ports`
  extension (one stereo output port), written into a scratch block by a
  start-chained data-init;
- a process trampoline that builds a `Vec<f32>` header over the host's
  channel-0 buffer, so the `@realtime` q64 `process` renders straight
  into host memory (zero copy — the `v.head` re-entry model), then
  mirrors channel 0 into channel 1.

`--wclap-id` / `--wclap-name` override the descriptor identity (defaults:
`dev.q64.voice` / `q64 Voice`).

The wrapped module must export the v0 plugin convention — the
audio-worklet surface: `alloc_f32(n) -> i64` (state buffer, by header
address) and `process(st, io, n, inc, b0, b1, b2, a1, a2, drive) -> i64`.

## Parameters

The shim serves `clap.params` with two automatable parameters:

| id | name | range | default | maps to |
|---|---|---|---|---|
| 0 | Frequency | 20–2000 Hz | 110 | `inc = 2·f/sr` |
| 1 | Drive | 1–4 | 1.8 | passed through |

Both reach the guest surface with pure arithmetic, and the guest already
one-pole-smooths every target in-state, so host automation lands
click-free. Param-value events are read from `in_events` the only way a
WCLAP plugin can — `call_indirect` through the size/get trampolines the
host installed into the plugin's table (the reason the table must be
growable) — with values snapped at block boundaries and clamped to range.
`value_to_text`/`text_to_value` return false (the host's default
formatting is right for plain Hz/ratio values). The filter stays fixed
(1 kHz Butterworth low-pass) until the declared `AudioPlugin` face lands
— its coefficients need trig the shim shouldn't synthesize.

## Check

```sh
node examples/audio-wclap/check.mjs examples/audio-wclap/voice.wclap.wasm
```

`check.mjs` is an **honest minimal WCLAP host**: it discovers everything
the way a real browser host does — reads the `clap_entry` global, walks
the CLAP structs in guest memory, calls every callback through
`__indirect_function_table`, allocates its own blocks with the plugin's
exported `malloc`, and learns the buses from `clap.audio-ports`. It never
touches the module's own exports. It drives the full lifecycle
(`entry.init` → factory → descriptor → `create_plugin` → `init` →
`activate(48000)` → `start_processing` → 400× `process` → `stop` →
`deactivate` → `destroy` → `entry.deinit`) and asserts the audio is the
same voice the worklet smoke test measures (~84.7 energy per 128-frame
block, state persisting across blocks, channel 1 mirroring channel 0).

For `clap.params` it goes further than reading the surface back: it
installs real host trampolines — a JS function can't enter a funcref
table, so it compiles a ~50-byte wasm module per signature (import
`env.f`, export it), grows the plugin's table, and `table.set`s the
exports, exactly what `wclap-host-js` does — then delivers a
`CLAP_EVENT_PARAM_VALUE` through `process`'s `in_events` and **measures
the pitch of the rendered audio** (rising zero-crossings): 110.0 Hz at
the default, 220.0 Hz after the event. `flush` outside processing and
out-of-range clamping are exercised the same way. A params test that
only checks `get_value` would pass with the DSP disconnected; measuring
the audio is what makes it honest.
