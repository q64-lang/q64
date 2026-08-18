# stdlib/audio → `q64.audio`

Audio I/O, DSP primitives, and audio-graph plumbing.

> **Status: v1 implemented** — `src/lib.q` ships the first DSP building
> blocks: stateful processors as structs with fit methods (`one_pole`
> smoother, `biquad` DF2T, `saw` oscillator — created by constructor
> functions, driven by `p.tick(x)` / `o.next()`), waveshapers
> (`soft_clip`, `tanh_fast`), `denormal_flush` (wasm has no FTZ — every
> recursive state update in the library flushes), `clamp1`, a
> caller-owned-buffer `delay_tick`, and turns-domain trig for in-guest
> filter-coefficient math (`sin2pi`/`cos2pi`, endpoint-constrained
> degree-7 polynomials, |err| < ~1e-6 on [0, 0.5] — no libm). All f32; per-sample free functions
> carry a checked `@realtime`. See `examples/audio-dsp/` for the smoke:
> saw → lowpass → soft clip, rendered offline. The rest of the surface
> below is still planned.

## Surface (planned)

- **PCM types** — `PCM<i16>`, `PCM<i32>`, `PCM<f32>`, `PCM<f64>` as distinct
  kinds; conversions are explicit named operations.
- **Audio I/O** — `env.audio.input()` and `env.audio.output()` capabilities
  returning `Signal<PCM<f32>>` (the canonical bus format).
- **DSP building blocks** — filters (biquad, FIR), oscillators, envelopes,
  delay lines, FFT-based effects.
- **MIDI** — `Event<MidiMessage>` from `env.midi.input()`.
- **Sample-rate types** — `Hz`, `kHz` as units; sample-rate mismatches caught
  at compile time.
- **Stream integration** — every primitive plugs into the same `Signal<...>`,
  `Event<...>`, `Stream<...>` vocabulary as the rest of the language.

Real-time-safe paths are marked `@realtime` and verified at compile time;
the audio-host runtime adapter pins these stages to the host's audio thread.
