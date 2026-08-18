# runtime/audio-host — native CLAP

The native plugin runtime adapter. **First target landed: CLAP** — a
`.clap` shared library that embeds wasmtime and runs a q64-compiled
wasm32 audio module in a desktop DAW. VST3 / AU wrappers around the
same core come later (`docs/audio-roadmap.md` phase D3).

> **Status: CLAP v1 implemented.** `zig build --release=fast` produces
> `zig-out/lib/libq64clap.so` (rename to `.clap` for a DAW) and
> `zig-out/bin/q64-clap-check`, the conformance harness.

## How it works

The plugin is the **native sibling of the WCLAP shim**
(`q64/src/codegen/wclap.zig`): it consumes the same guest plugin
convention (`spec/audio-face.md` §interim convention) — it never
emulates the browser WCLAP table ABI, it just calls the guest's exports
from native CLAP callbacks through wasmtime:

- `src/clap.zig` — the CLAP C ABI (clap-1.2) as Zig extern structs:
  entry / factory / descriptor / plugin / process / events / params /
  audio-ports / note-ports.
- `src/main.zig` — the shim. `entry.init` loads the wasm (`q64.wasm`
  beside the `.clap`, or `Q64_CLAP_WASM`), instantiates it (q64 audio
  modules are import-free), and resolves the convention exports. v1
  requires the full convention — the `examples/audio-poly` surface —
  with `midi` optional.

The audio path: the guest renders into a guest-side `Vec<f32>` io
buffer allocated at activate; event application is
**sample-offset-accurate** via the same split-the-block walk the WCLAP
shim does (per segment the host rewrites the io vec header in guest
memory and calls guest `process`); one copy-out per block moves the
frames into the host's channel buffers. Parameters are served from the
guest's own table (`param_count`/`param_info`/`param_name` via calls,
names byte-by-byte). All guest calls take one spin mutex — a wasmtime
store is not thread-safe, and CLAP calls params from the main thread
while process runs on the audio thread; v1 serializes and says so.

## Build & check

```sh
# the guest (no --wclap — the native shim consumes the raw convention)
q64/zig-out/bin/q64 emit examples/audio-poly/src/lib.q q64.wasm \
  --addr wasm32 --module q64.audio=$PWD/stdlib/audio/src/lib.q --release

cd runtime/audio-host
zig build --release=fast
./zig-out/bin/q64-clap-check ./zig-out/lib/libq64clap.so ../../q64.wasm
```

`q64-clap-check` is an honest minimal native host: it dlopens the
plugin exactly like a DAW, resolves the `clap_entry` symbol, and drives
the full lifecycle with real `clap_process` blocks and real input-event
lists. Asserted in the rendered audio: silence before the first note,
note-on key 69 at a measured ~440 Hz, cutoff automation by
params-extension readback, note-off release to silence, and the
sample-offset boundary (a `time=64` note-on leaves the block's first 64
samples exactly zero).

## Deploying into a DAW

Copy `libq64clap.so` to your CLAP directory as `q64poly.clap`, put the
compiled `q64.wasm` beside it (or set `Q64_CLAP_WASM`), and ship
`libwasmtime.so` next to the `.clap` (the rpath includes `$ORIGIN`).
Linux-first; macOS/Windows builds are the same Zig code with per-OS
packaging still to do.
