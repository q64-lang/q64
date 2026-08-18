# audio-poly — an 8-voice polyphonic synth, notes handled in-guest

The polyphonic counterpart to `examples/audio-wclap`: a WCLAP instrument
whose note handling lives entirely in q64 code. The shim only routes —
when a wrapped module exports the optional plugin-convention extensions
(`spec/audio-face.md` §interim convention)

```
state_cells() -> i64                          // own state sizing
prepare(ref st, sr: f64) -> i64               // at activate
note_on(ref st, key: i64, vel: f32) -> i64    // @realtime
note_off(ref st, key: i64) -> i64             // @realtime
```

note events are forwarded to the guest instead of driving the shim's
mono fallback. Voice allocation (re-strike, free-voice scan, round-robin
steal), the per-voice one-pole envelope, and the pitch table are all in
`src/lib.q`. The per-key saw increments are built at `prepare` by
walking the equal-temperament semitone ratio up from MIDI key 0 — no
`exp2` anywhere, guest or shim.

Voice mix → one shared low-pass → soft clip; the mono convention's
positional `inc`/`gain` arguments are ignored (pitch and envelope are
per-voice), `b0…a2`/`drive` still shape the tone.

## Build

```sh
q64/zig-out/bin/q64 emit examples/audio-poly/src/lib.q \
  examples/audio-poly/poly.wclap.wasm \
  --addr wasm32 --module q64.audio=$PWD/stdlib/audio/src/lib.q \
  --release --wclap --wclap-id dev.q64.poly --wclap-name "q64 Poly"
```

## Check

```sh
node examples/audio-poly/check.mjs examples/audio-poly/poly.wclap.wasm
```

Same honest-host rules as the mono check (which owns the full
static-surface verification); this one proves the notes-in-guest path in
the rendered audio: **silent before the first note** (a note-driven
instrument free-runs nowhere), a chord raises the RMS, **releasing A4
leaves E5 sounding at its own measured pitch** (the voice-independence
proof), mass release after a 10-note cluster on 8 voices decays to
silence (nothing sticks through voice stealing).

In the reference browser host it loads and idles silent
(`host-smoke.mjs … --expect-silent`); with a MIDI keyboard attached it
plays — the host's Web-MIDI note encoder matches the event layout the
shim forwards.
