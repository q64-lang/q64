# audio-web — the first q64 audio in a browser

The `q64.audio` synth voice (saw → DF2T Butterworth lowpass → cubic soft
clipper), compiled by `q64` to wasm32 and played through the Web Audio
API. Three sliders — frequency, cutoff, drive — re-render two seconds of
audio through the wasm on every change (~100 ms for 96 000 samples in a
debug build) and draw the waveform.

```sh
# build the wasm (from this folder)
qube build --addr wasm32

# verify without a browser: renders a voice in node and checks the samples
node test.mjs

# serve and open
python3 -m http.server 8000
# → http://localhost:8000/web/
```

## How it works

- [`src/lib.q`](./src/lib.q) exports one function:
  `render(n, inc, b0, b1, b2, a1, a2, drive) -> i64` — fills a fresh
  `Vec<f32>` with `n` samples of the voice and returns the buffer's
  linear-memory address (`buf.ptr`). The host reads `n` f32s at that
  address. i64 crosses the JS boundary as `BigInt`.
- [`web/index.html`](./web/index.html) computes the biquad coefficients
  from the cutoff slider (RBJ cookbook — this design math moves into
  `q64.audio` once `q64.math` grows its f32 tier), calls `render`, copies
  the samples into an `AudioBuffer`, and loops it.
- The module is stateless and v0's vec heap is never reclaimed, so the
  page instantiates a fresh instance per render — instantiation is far
  cheaper than the render itself.

This page is the offline-render half of the browser story; the live half
(an AudioWorklet driving a persistent q64 instance block-by-block) arrives
with the `env.audio` face and the WCLAP target
(`docs/audio-roadmap.md` phase D).
