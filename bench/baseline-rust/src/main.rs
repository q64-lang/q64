//! Rust baseline for bench/kernels/*.q — the same seven DSP kernels, same
//! math, same output line protocol. Built for wasm32-wasip1 and run under
//! the vendored wasmtime CLI, so the comparison is wasm-vs-wasm.
//!
//! Every kernel mirrors its .q twin operation-for-operation (same input
//! recurrences, same coefficients, same accumulation), so a divergent
//! checksum means a real semantic difference, not benchmark noise.
//! `black_box` pins the loop-invariant constants so LLVM cannot
//! strength-reduce a recurrence the q64 side actually executes.

use std::hint::black_box;
use std::time::Instant;

const REPS: usize = 7;

fn timed<F: FnMut(i64) -> f64>(name: &str, samples: i64, n: i64, mut f: F) {
    let mut best = u128::MAX;
    let mut check = 0.0;
    for _ in 0..REPS {
        // n goes through black_box on every rep: the kernel's result must
        // not be loop-invariant, or LLVM hoists the whole (pure) kernel out
        // of the timed region and the clock brackets nothing.
        let t0 = Instant::now();
        check = black_box(f(black_box(n)));
        let dt = t0.elapsed().as_nanos();
        if dt < best {
            best = dt;
        }
    }
    println!("bench {name} samples {samples} ns {best} check {check}");
}

fn mac_f32(n: i64) -> f64 {
    let mut acc: f32 = 0.0;
    let mut x: f32 = 1.0;
    let r: f32 = black_box(0.9999995);
    let g: f32 = black_box(0.5);
    let mut i: i64 = 0;
    while i < n {
        acc += x * g;
        x *= r;
        i += 1;
    }
    acc as f64
}

fn mac_simd4(n: i64) -> f64 {
    // Four independent scalar lanes; LLVM vectorizes this to f32x4 on
    // wasm32 with +simd128, matching the q64 Simd<f32, 4> kernel.
    let mut a = [0.0f32; 4];
    let mut x = [1.0f32; 4];
    let r: f32 = black_box(0.9999995);
    let g: f32 = black_box(0.5);
    let mut i: i64 = 0;
    while i < n {
        for l in 0..4 {
            a[l] += x[l] * g;
            x[l] *= r;
        }
        i += 1;
    }
    a.iter().map(|v| *v as f64).sum()
}

fn clip_simd4(n: i64) -> f64 {
    // Four lanes, branch-free clamp via min/max; LLVM vectorizes to f32x4
    // with +simd128, matching the q64 Simd kernel.
    let mut x = [0.5f32; 4];
    let growth: f32 = black_box(1.0000004);
    let mut acc = [0.0f32; 4];
    let mut i: i64 = 0;
    while i < n {
        for l in 0..4 {
            x[l] *= growth;
            let t = 1.5 - 0.5 * x[l] * x[l];
            let y = (x[l] * t).min(1.0).max(-1.0);
            acc[l] += y;
        }
        i += 1;
    }
    acc.iter().map(|v| *v as f64).sum()
}

fn mix04(n: i64) -> f64 {
    let mut p = [0.0f32, 0.25, 0.5, 0.75];
    let inc = black_box([0.010986f32, 0.014648, 0.021973, 0.032959]);
    let g = black_box([0.35f32, 0.3, 0.25, 0.2]);
    let mut acc: f32 = 0.0;
    let mut i: i64 = 0;
    while i < n {
        for c in 0..4 {
            p[c] += inc[c];
            if p[c] > 1.0 {
                p[c] -= 2.0;
            }
        }
        let mixed = p[0] * g[0] + p[1] * g[1] + p[2] * g[2] + p[3] * g[3];
        acc += mixed;
        i += 1;
    }
    acc as f64
}

fn biquad4(n: i64) -> f64 {
    let b0: f32 = black_box(0.000944692);
    let b1: f32 = black_box(0.001889384);
    let b2: f32 = black_box(0.000944692);
    let a1: f32 = black_box(-1.911196288);
    let a2: f32 = black_box(0.914975055);
    let mut ph: f32 = 0.0;
    let inc: f32 = black_box(0.010986);
    let mut s1 = [0.0f32; 4];
    let mut s2 = [0.0f32; 4];
    let mut acc: f32 = 0.0;
    let mut i: i64 = 0;
    while i < n {
        ph += inc;
        if ph > 1.0 {
            ph -= 2.0;
        }
        let mut x = ph;
        for k in 0..4 {
            let y = b0 * x + s1[k];
            s1[k] = b1 * x - a1 * y + s2[k];
            s2[k] = b2 * x - a2 * y;
            x = y;
        }
        acc += x;
        i += 1;
    }
    acc as f64
}

fn fir16(n: i64) -> f64 {
    let c: [f32; 16] = black_box([
        0.003, 0.009, 0.021, 0.041, 0.066, 0.092, 0.113, 0.125, 0.125, 0.113, 0.092, 0.066,
        0.041, 0.021, 0.009, 0.003,
    ]);
    let mut x = [0.0f32; 16];
    let mut ph: f32 = 0.0;
    let inc: f32 = black_box(0.010986);
    let mut acc: f32 = 0.0;
    let mut i: i64 = 0;
    while i < n {
        ph += inc;
        if ph > 1.0 {
            ph -= 2.0;
        }
        for k in (1..16).rev() {
            x[k] = x[k - 1];
        }
        x[0] = ph;
        let mut y: f32 = 0.0;
        for k in 0..16 {
            y += c[k] * x[k];
        }
        acc += y;
        i += 1;
    }
    acc as f64
}

fn softclip(n: i64) -> f64 {
    let mut ph: f32 = 0.0;
    let inc: f32 = black_box(0.010986);
    let mut drive: f32 = 0.5;
    let step: f32 = black_box(0.0000037);
    let mut dinc: f32 = step;
    let mut acc: f32 = 0.0;
    let mut i: i64 = 0;
    while i < n {
        ph += inc;
        if ph > 1.0 {
            ph -= 2.0;
        }
        drive += dinc;
        if drive > 2.0 {
            dinc = -step;
        }
        if drive < 0.5 {
            dinc = step;
        }
        let x = ph * drive;
        let mut y = x * (1.5 - 0.5 * x * x);
        if x > 1.0 {
            y = 1.0;
        }
        if x < -1.0 {
            y = -1.0;
        }
        acc += y;
        i += 1;
    }
    acc as f64
}

fn wavetable16(n: i64) -> f64 {
    let table: [f64; 16] = black_box([
        0.0, 0.38268, 0.70711, 0.92388, 1.0, 0.92388, 0.70711, 0.38268, 0.0, -0.38268,
        -0.70711, -0.92388, -1.0, -0.92388, -0.70711, -0.38268,
    ]);
    let mut idx: usize = 0;
    let mut frac: f64 = 0.0;
    let finc: f64 = black_box(0.37);
    let mut acc: f64 = 0.0;
    let mut i: i64 = 0;
    while i < n {
        frac += finc;
        if frac >= 1.0 {
            frac -= 1.0;
            idx += 1;
        }
        if idx >= 16 {
            idx = 0;
        }
        let mut j = idx + 1;
        if j >= 16 {
            j = 0;
        }
        let y = table[idx] * (1.0 - frac) + table[j] * frac;
        acc += y * y;
        i += 1;
    }
    acc
}

fn main() {
    timed("mac_f32", 4_000_000, 4_000_000, mac_f32);
    timed("mac_simd4", 4_000_000, 1_000_000, mac_simd4);
    timed("clip_simd4", 4_000_000, 1_000_000, clip_simd4);
    timed("mix04", 2_000_000, 2_000_000, mix04);
    timed("biquad4", 1_000_000, 1_000_000, biquad4);
    timed("fir16", 1_000_000, 1_000_000, fir16);
    timed("softclip", 2_000_000, 2_000_000, softclip);
    timed("wavetable16", 2_000_000, 2_000_000, wavetable16);
}
