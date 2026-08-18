//! audio-dsp — a tiny synth voice, rendered offline.
//!
//!   saw(110 Hz @ 48 kHz) → biquad lowpass (~1 kHz) → soft_clip(drive 1.8)
//!
//! One second of audio (48 000 samples) into a caller-owned Vec<f32>
//! buffer, then a summary: the signal's energy (sum of squares) and its
//! peak — the offline-render smoke for the q64.audio building blocks.
//! Proves: stdlib structs + fit methods cross-module, stateful ticks,
//! out-mode buffers, and the `@realtime` render path.

import q64.audio.{saw, biquad, soft_clip}

// Render `n` samples of the voice into `buf[0..n)`. The processors are
// built by the caller and advance their internal state per sample.
fn render(out buf: Vec<f32>, n: i64) {
    // 110 Hz saw at 48 kHz: inc = 2·110/48000.
    var osc = saw(f32(0.00458333))
    // Butterworth lowpass, fc ≈ 1 kHz @ 48 kHz (precomputed, a0-normalized).
    var lp = biquad(f32(0.000944692), f32(0.001889384), f32(0.000944692), f32(-1.911196288), f32(0.914975055))
    let drive = f32(1.8)
    var i = 0
    while i < n {
        let s = osc.next()
        let f = lp.tick(s)
        buf[i] = soft_clip(f * drive)
        i = i + 1
    }
}

fn main {
    let n = 48000
    var buf: Vec<f32> = Vec.new()
    var i = 0
    while i < n {
        buf.push(f32(0.0))
        i = i + 1
    }

    render(buf, n)

    var energy = 0.0
    var peak = f32(0.0)
    var j = 0
    while j < n {
        let s = buf[j]
        energy = energy + f64(s) * f64(s)
        var a = s
        if a < f32(0.0) { a = f32(0.0) - a }
        if a > peak { peak = a }
        j = j + 1
    }
    let s0 = buf[100]
    let s1 = buf[24000]
    env.out("audio-dsp: {n} samples")
    env.out("energy {energy} peak {peak}")
    env.out("probe {s0} {s1}")
}
