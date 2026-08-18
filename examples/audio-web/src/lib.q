//! audio-web — the synth voice as a browser-callable surface.
//!
//! exports: render
//!
//! `render` fills a fresh buffer with `n` samples of the voice — saw
//! oscillator into a DF2T lowpass into the soft clipper, all from
//! `q64.audio` — and returns the buffer's linear-memory address. The
//! host (web/index.html) reads `n` f32s at that address and hands them
//! to the Web Audio API. Stateless by design: the vec heap is
//! never reclaimed in v0, so the page re-instantiates the module per
//! render instead of accumulating leaked buffers.
//!
//! The biquad coefficients arrive precomputed (the host derives them
//! from the cutoff slider) — the coefficient-design helpers land with
//! `q64.math`'s f32 tier.

import q64.audio.{saw, biquad, soft_clip}

pub fn render(n: i64, inc: f32, b0: f32, b1: f32, b2: f32, a1: f32, a2: f32, drive: f32) -> i64 {
    var buf: Vec<f32> = Vec.new()
    var i = 0
    while i < n {
        buf.push(f32(0.0))
        i = i + 1
    }
    var osc = saw(inc)
    var lp = biquad(b0, b1, b2, a1, a2)
    var j = 0
    while j < n {
        let s = osc.next()
        let f = lp.tick(s)
        buf[j] = soft_clip(f * drive)
        j = j + 1
    }
    buf.ptr
}
