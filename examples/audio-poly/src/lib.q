//! audio-poly — an 8-voice polyphonic saw synth, notes handled in-guest.
//!
//! exports: alloc_f32, data_of, state_cells, prepare, note_on, note_off,
//!          process
//!
//! The full optional plugin convention (spec/audio-face.md §interim
//! convention): the WCLAP shim forwards note events here instead of
//! driving its mono fallback, so polyphony, voice stealing, and the
//! per-voice envelope are all q64 code — the shim only routes.
//!
//! State layout (state_cells() = 176 cells):
//!   [0..128)   per-key saw increment (2·f/sr), written by prepare —
//!              built by ratio walk from MIDI key 0, no exp2 needed
//!   [128..168) 8 voices × 5: key, inc, phase, env, gate
//!   [168]      round-robin steal cursor
//!   [169..171) shared biquad s1, s2
//!
//! Per sample: sum the active saws (env one-pole-chases gate — that ramp
//! is the ~7 ms attack/release), then one shared lowpass + soft clip on
//! the mix. A voice is active while env is audible or its gate is open;
//! a fully released voice is reclaimable.

import q64.audio.{soft_clip, denormal_flush}

let VOICES = 8
let VBASE = 128
let VSIZE = 5
let CURSOR = 168
let FS1 = 169
let FS2 = 170

// A zeroed Vec<f32> of n cells, handed to the host by header address.
pub fn alloc_f32(n: i64) -> i64 {
    var v: Vec<f32> = Vec.new()
    var i = 0
    while i < n {
        v.push(f32(0.0))
        i = i + 1
    }
    v.head
}

pub fn data_of(v: Vec<f32>) -> i64 {
    v.ptr
}

// The shim sizes the state vec from this at plugin.init.
pub fn state_cells() -> i64 {
    171
}

// Activate-time (allocation still allowed, rate first known): build the
// per-key increment table by walking the equal-temperament ratio up from
// MIDI key 0 (C-1, 8.17579891564371 Hz). No exp2 required.
pub fn prepare(ref st: Vec<f32>, sr: f64) -> i64 {
    var f = 8.17579891564371
    let ratio = 1.0594630943592953
    var k = 0
    while k < 128 {
        st[k] = f32(2.0 * f / sr)
        f = f * ratio
        k = k + 1
    }
    0
}

// Claim a voice: a re-strike of the same key first, else a silent voice,
// else round-robin steal.
pub fn note_on(ref st: Vec<f32>, key: i64, vel: f32) -> i64 @realtime {
    var slot = -1
    var v = 0
    while v < VOICES {
        let base = VBASE + v * VSIZE
        if st[base] == f32(key) && st[base + 4] > f32(0.0) { slot = v }
        v = v + 1
    }
    if slot < 0 {
        v = 0
        while v < VOICES {
            let base = VBASE + v * VSIZE
            if slot < 0 && st[base + 3] < f32(0.0001) && st[base + 4] == f32(0.0) {
                slot = v
            }
            v = v + 1
        }
    }
    if slot < 0 {
        slot = i64(st[CURSOR])
        st[CURSOR] = f32((slot + 1) % VOICES)
    }
    let base = VBASE + slot * VSIZE
    st[base] = f32(key)
    st[base + 1] = st[key]
    st[base + 4] = vel
    0
}

// Release every voice holding this key (env ramps down in process).
pub fn note_off(ref st: Vec<f32>, key: i64) -> i64 @realtime {
    var v = 0
    while v < VOICES {
        let base = VBASE + v * VSIZE
        if st[base] == f32(key) {
            st[base + 4] = f32(0.0)
        }
        v = v + 1
    }
    0
}

// One block: mix the voices, filter and clip the sum. The positional
// mono-convention params still arrive; a note-handling guest ignores
// inc and gain (pitch and envelope are per-voice) and keeps the filter
// coefficients + drive.
pub fn process(ref st: Vec<f32>, out io: Vec<f32>, n: i64,
               inc: f32, b0: f32, b1: f32, b2: f32, a1: f32, a2: f32,
               drive: f32, gain: f32) -> i64 @realtime {
    let sm = f32(0.003)
    var s1 = st[FS1]
    var s2 = st[FS2]
    var i = 0
    while i < n {
        var mix = f32(0.0)
        var v = 0
        while v < VOICES {
            let base = VBASE + v * VSIZE
            var env = st[base + 3]
            let gate = st[base + 4]
            if env > f32(0.0001) || gate > f32(0.0) {
                env = env + sm * (gate - env)
                var ph = st[base + 2] + st[base + 1]
                if ph > f32(1.0) { ph = ph - f32(2.0) }
                st[base + 2] = ph
                st[base + 3] = denormal_flush(env)
                mix = mix + ph * env
            }
            v = v + 1
        }
        let x = mix * f32(0.35)
        let y = b0 * x + s1
        s1 = denormal_flush(b1 * x - a1 * y + s2)
        s2 = denormal_flush(b2 * x - a2 * y)
        io[i] = soft_clip(y * drive)
        i = i + 1
    }
    st[FS1] = s1
    st[FS2] = s2
    n
}
