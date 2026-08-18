//! audio-worklet — a persistent, block-driven synth voice.
//!
//! exports: alloc_f32, data_of, process
//!
//! The host instantiates once, allocates two buffers through the guest —
//! a state vec and an io vec — and holds each by its *header* address
//! (`v.head`). Every audio quantum it calls
//! `process(state, io, n, inc, b0…a2, drive)`: the Vec parameters
//! reconnect the same buffers, so oscillator phase, filter state, and
//! the smoothed parameter values persist across calls. Parameters are
//! smoothed in-guest with one-pole ramps (~6 ms at 48 kHz), so host-side
//! slider jumps land click-free.
//!
//! State layout (state[0..10)):
//!   0 osc phase   1 biquad s1   2 biquad s2
//!   3 sm inc      4 sm b0   5 sm b1   6 sm b2   7 sm a1   8 sm a2
//!   9 sm drive

import q64.audio.{soft_clip, denormal_flush}

// A zeroed Vec<f32> of n cells, handed to the host by header address —
// the re-entry handle for the `Vec<f32>` parameters below.
pub fn alloc_f32(n: i64) -> i64 {
    var v: Vec<f32> = Vec.new()
    var i = 0
    while i < n {
        v.push(f32(0.0))
        i = i + 1
    }
    v.head
}

// The element-data address of a host-held buffer — where the host reads
// the rendered samples.
pub fn data_of(v: Vec<f32>) -> i64 {
    v.ptr
}

// One audio quantum: smooth the targets, then render n samples of
// saw → DF2T lowpass → soft clip into io[0..n). Returns the frames
// rendered (the CLAP-process-status convention — and v0's main-less
// surface pass exports value-returning fns only).
pub fn process(ref st: Vec<f32>, out io: Vec<f32>, n: i64,
               inc: f32, b0: f32, b1: f32, b2: f32, a1: f32, a2: f32,
               drive: f32) -> i64 @realtime {
    let sm = f32(0.003)
    var ph = st[0]
    var s1 = st[1]
    var s2 = st[2]
    var c_inc = st[3]
    var c_b0 = st[4]
    var c_b1 = st[5]
    var c_b2 = st[6]
    var c_a1 = st[7]
    var c_a2 = st[8]
    var c_dr = st[9]
    var i = 0
    while i < n {
        c_inc = c_inc + sm * (inc - c_inc)
        c_b0 = c_b0 + sm * (b0 - c_b0)
        c_b1 = c_b1 + sm * (b1 - c_b1)
        c_b2 = c_b2 + sm * (b2 - c_b2)
        c_a1 = c_a1 + sm * (a1 - c_a1)
        c_a2 = c_a2 + sm * (a2 - c_a2)
        c_dr = c_dr + sm * (drive - c_dr)
        ph = ph + c_inc
        if ph > f32(1.0) { ph = ph - f32(2.0) }
        let y = c_b0 * ph + s1
        s1 = denormal_flush(c_b1 * ph - c_a1 * y + s2)
        s2 = denormal_flush(c_b2 * ph - c_a2 * y)
        io[i] = soft_clip(y * c_dr)
        i = i + 1
    }
    st[0] = ph
    st[1] = s1
    st[2] = s2
    st[3] = c_inc
    st[4] = c_b0
    st[5] = c_b1
    st[6] = c_b2
    st[7] = c_a1
    st[8] = c_a2
    st[9] = c_dr
    n
}
