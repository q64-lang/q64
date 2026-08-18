# audio-worklet — a live, persistent q64 voice

The live half of the browser audio story: **one persistent q64 wasm
instance on the audio thread**, driven block-by-block by an AudioWorklet.
Where [`audio-web`](../audio-web) re-renders offline on every slider move,
this page keeps the sound running — oscillator phase and filter state
persist across `process()` calls, and parameter changes are smoothed
*inside the q64 code* (one-pole ramps, ~6 ms), so slider moves are
click-free. A debug build spends ~2 µs of the 2 667 µs budget per
128-frame quantum at 48 kHz.

```sh
qube build --addr wasm32     # from this folder
node test.mjs                # drive 400 quanta headlessly, assert output
python3 -m http.server 8000  # then open http://localhost:8000/web/
```

## The persistence pattern

Wasm exports are stateless, so state lives in guest `Vec<f32>` buffers the
host holds **by header address**:

- `alloc_f32(n) -> i64` — the guest allocates a zeroed buffer and returns
  `v.head`, the vec *header* address (the language surface added for this:
  the sibling of `v.ptr`).
- `process(ref st: Vec<f32>, out io: Vec<f32>, n, …params) -> i64` — a
  header address passed back into a `Vec<f32>` parameter reconnects the
  same buffer, so `st` carries phase/filter/smoothed-parameter state from
  quantum to quantum and `io` receives the samples. `@realtime`-checked;
  returns frames rendered (the CLAP process-status convention).
- `data_of(v) -> i64` — `v.ptr`, where the host reads the samples.

[`web/processor.js`](./web/processor.js) is the whole host: instantiate
from bytes in the worklet (Chromium won't transfer a compiled module over
the port), allocate the two buffers, call `process` per quantum, copy out.
It posts `"ready"` once instantiated — an `OfflineAudioContext` renders
faster than real time and must wait for it (the headless smoke does).

This is the AudioWorklet precursor of the WCLAP target
(`docs/audio-roadmap.md` phase D): the same persistent-instance,
block-driven, host-owned-buffer shape, minus the CLAP ABI.
