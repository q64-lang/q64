# stdlib/audio → `q64.audio`

Audio I/O, DSP primitives, and audio-graph plumbing.

> **Status: not yet implemented.**

## Surface (planned)

- **PCM types** — `PCM.<i16>`, `PCM.<i32>`, `PCM.<f32>`, `PCM.<f64>` as distinct
  kinds; conversions are explicit named operations.
- **Audio I/O** — `env.audio.input()` and `env.audio.output()` capabilities
  returning `Signal.<PCM.<f32>>` (the canonical bus format).
- **DSP building blocks** — filters (biquad, FIR), oscillators, envelopes,
  delay lines, FFT-based effects.
- **MIDI** — `Event.<MidiMessage>` from `env.midi.input()`.
- **Sample-rate types** — `Hz`, `kHz` as units; sample-rate mismatches caught
  at compile time.
- **Stream integration** — every primitive plugs into the same `Signal.<...>`,
  `Event.<...>`, `Stream.<...>` vocabulary as the rest of the language.

Real-time-safe paths are marked `@realtime` and verified at compile time;
the audio-host runtime adapter pins these stages to the host's audio thread.
