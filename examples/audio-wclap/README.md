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
In v0 the trampoline fixes the voice parameters (110 Hz, 1 kHz low-pass,
drive 1.8); `clap.params` is the next slice.

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
