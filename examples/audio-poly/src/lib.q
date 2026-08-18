//! audio-poly — an 8-voice polyphonic saw synth; notes AND parameters
//! handled in-guest.
//!
//! exports: alloc_f32, data_of, state_cells, prepare, note_on, note_off,
//!          midi, param_count, param_info, param_name, set_param,
//!          get_param, process
//!
//! The full optional plugin convention (spec/audio-face.md §interim
//! convention). The WCLAP shim forwards note events AND parameter
//! events here and reads the parameter table from these exports — the
//! shim is a pure router; pitch, envelopes, voice stealing, parameter
//! ranges, and the filter-coefficient math are all q64 code. Cutoff is
//! finally a real parameter: RBJ low-pass coefficients computed in-guest
//! with `q64.audio.sin2pi`/`cos2pi` (no libm anywhere).
//!
//! State layout (state_cells() = 185 cells):
//!   [0..128)   per-key saw increment (2·f/sr), ratio-walk, no exp2
//!   [128..168) 8 voices × 5: key, inc, phase, env, gate
//!   [168]      round-robin steal cursor
//!   [169..171) shared biquad s1, s2
//!   [171]      sample rate
//!   [172..174) parameter shadows: cutoff, drive
//!   [174..179) coefficient targets b0, b1, b2, a1, a2
//!   [179..185) smoothed b0, b1, b2, a1, a2, drive

import q64.audio.{soft_clip, denormal_flush, sin2pi, cos2pi}

let VOICES = 8
let VBASE = 128
let VSIZE = 5
let CURSOR = 168
let FS1 = 169
let FS2 = 170
let SR = 171
let P_CUTOFF = 172
let P_DRIVE = 173
let CT = 174
let SM = 179

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

pub fn state_cells() -> i64 {
    185
}

// RBJ low-pass at the shadowed cutoff, Q = 0.7071 (Butterworth), into
// the coefficient-target cells. Runs at prepare and on each cutoff
// set_param — block-boundary, never per sample.
fn lp_coeffs(ref st: Vec<f32>) -> i64 @realtime {
    let w = st[P_CUTOFF] / st[SR]
    let s = sin2pi(w)
    let c = cos2pi(w)
    let alpha = s / f32(1.4142135)
    let a0 = f32(1.0) + alpha
    let b1 = (f32(1.0) - c) / a0
    st[CT] = b1 * f32(0.5)
    st[CT + 1] = b1
    st[CT + 2] = b1 * f32(0.5)
    st[CT + 3] = f32(-2.0) * c / a0
    st[CT + 4] = (f32(1.0) - alpha) / a0
    0
}

// Activate-time: increment table by ratio walk from MIDI key 0
// (8.17579891564371 Hz), parameter defaults, initial coefficients.
pub fn prepare(ref st: Vec<f32>, sr: f64) -> i64 {
    var f = 8.17579891564371
    let ratio = 1.0594630943592953
    var k = 0
    while k < 128 {
        st[k] = f32(2.0 * f / sr)
        f = f * ratio
        k = k + 1
    }
    st[SR] = f32(sr)
    st[P_CUTOFF] = f32(1000.0)
    st[P_DRIVE] = f32(1.8)
    lp_coeffs(st)
}

// ---- the guest-declared parameter table -----------------------------
// id 0: Cutoff, 100..8000 Hz, default 1000
// id 1: Drive, 1..4, default 1.8

pub fn param_count() -> i64 {
    2
}

// field: 0 = id, 1 = min, 2 = max, 3 = default, 4 = flags
// (flags bit 5 = CLAP_PARAM_IS_AUTOMATABLE).
pub fn param_info(i: i64, field: i64) -> f64 {
    var r = 0.0
    if field == 0 { r = f64(i) }
    if field == 4 { r = 32.0 }
    if i == 0 {
        if field == 1 { r = 100.0 }
        if field == 2 { r = 8000.0 }
        if field == 3 { r = 1000.0 }
    }
    if i == 1 {
        if field == 1 { r = 1.0 }
        if field == 2 { r = 4.0 }
        if field == 3 { r = 1.8 }
    }
    r
}

// Byte j of parameter i's name; 0 terminates. Scalar-only on purpose —
// no string ABI crosses the boundary.
pub fn param_name(i: i64, j: i64) -> i64 {
    var ch = 0
    if i == 0 {
        if j == 0 { ch = 67 }  // C
        if j == 1 { ch = 117 } // u
        if j == 2 { ch = 116 } // t
        if j == 3 { ch = 111 } // o
        if j == 4 { ch = 102 } // f
        if j == 5 { ch = 102 } // f
    }
    if i == 1 {
        if j == 0 { ch = 68 }  // D
        if j == 1 { ch = 114 } // r
        if j == 2 { ch = 105 } // i
        if j == 3 { ch = 118 } // v
        if j == 4 { ch = 101 } // e
    }
    ch
}

// A new target from the host. The guest owns clamping and any derived
// math (cutoff -> coefficients); process smooths toward the targets.
pub fn set_param(ref st: Vec<f32>, id: i64, value: f64) -> i64 @realtime {
    if id == 0 {
        var c = f32(value)
        if c < f32(100.0) { c = f32(100.0) }
        if c > f32(8000.0) { c = f32(8000.0) }
        st[P_CUTOFF] = c
        // let-bound: a statement-position call with a ref-Vec argument
        // is a known v0 papercut (UnsupportedExpression).
        let applied = lp_coeffs(st)
    }
    if id == 1 {
        var d = f32(value)
        if d < f32(1.0) { d = f32(1.0) }
        if d > f32(4.0) { d = f32(4.0) }
        st[P_DRIVE] = d
    }
    0
}

pub fn get_param(ref st: Vec<f32>, id: i64) -> f64 {
    var r = 0.0
    if id == 0 { r = f64(st[P_CUTOFF]) }
    if id == 1 { r = f64(st[P_DRIVE]) }
    r
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

// Raw MIDI the host didn't translate (notes arrive as clap note events;
// this gets the rest — CC, pitch bend, aftertouch). CC 1 (mod wheel) on
// any channel sweeps the cutoff across its full range, through
// set_param so clamping and the coefficient math are shared.
pub fn midi(ref st: Vec<f32>, b0: i64, b1: i64, b2: i64) -> i64 @realtime {
    if (b0 & 240) == 176 && b1 == 1 {
        let applied = set_param(st, 0, 100.0 + f64(b2) * 62.2)
    }
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

// One block: mix the voices, smooth the coefficient/drive targets,
// filter and clip the sum. A guest that declares its own parameters
// gets the short process signature — no positional targets.
pub fn process(ref st: Vec<f32>, out io: Vec<f32>, n: i64) -> i64 @realtime {
    let sm = f32(0.003)
    var s1 = st[FS1]
    var s2 = st[FS2]
    var c_b0 = st[SM]
    var c_b1 = st[SM + 1]
    var c_b2 = st[SM + 2]
    var c_a1 = st[SM + 3]
    var c_a2 = st[SM + 4]
    var c_dr = st[SM + 5]
    var i = 0
    while i < n {
        c_b0 = c_b0 + sm * (st[CT] - c_b0)
        c_b1 = c_b1 + sm * (st[CT + 1] - c_b1)
        c_b2 = c_b2 + sm * (st[CT + 2] - c_b2)
        c_a1 = c_a1 + sm * (st[CT + 3] - c_a1)
        c_a2 = c_a2 + sm * (st[CT + 4] - c_a2)
        c_dr = c_dr + sm * (st[P_DRIVE] - c_dr)
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
        let y = c_b0 * x + s1
        s1 = denormal_flush(c_b1 * x - c_a1 * y + s2)
        s2 = denormal_flush(c_b2 * x - c_a2 * y)
        io[i] = soft_clip(y * c_dr)
        i = i + 1
    }
    st[FS1] = s1
    st[FS2] = s2
    st[SM] = c_b0
    st[SM + 1] = c_b1
    st[SM + 2] = c_b2
    st[SM + 3] = c_a1
    st[SM + 4] = c_a2
    st[SM + 5] = c_dr
    n
}
