// Node smoke for the audio-web surface: instantiate the built wasm, render
// a voice, and sanity-check the samples — no browser required. Exits 0 on
// success. Run after `qube build --addr wasm32`:
//
//   node test.mjs
import { readFileSync } from "node:fs";

const bytes = readFileSync(new URL("./target/debug/wasm32/dev.q64.audio_web.wasm", import.meta.url));
const { instance } = await WebAssembly.instantiate(bytes, { env: {} });

const n = 4800;
const ptr = Number(instance.exports.render(
  BigInt(n), 0.00458333, // 110 Hz @ 48 kHz
  0.000944692, 0.001889384, 0.000944692, -1.911196288, 0.914975055, // ~1 kHz lowpass
  1.8));
const s = new Float32Array(instance.exports.memory.buffer, ptr, n);

let energy = 0, peak = 0;
for (const x of s) { energy += x * x; peak = Math.max(peak, Math.abs(x)); }

// The voice is hot (driven into the clipper): peak must clip at exactly 1,
// energy must land near the known render (~3295 for this tenth-second),
// and the samples must match the audio-dsp example's probe value.
const near = (a, b, tol) => Math.abs(a - b) <= tol;
if (peak !== 1) throw new Error(`peak ${peak}, expected 1 (clipper engaged)`);
if (!near(energy, 3295, 40)) throw new Error(`energy ${energy}, expected ~3295`);
if (!near(s[100], 0.835213, 1e-4)) throw new Error(`s[100] ${s[100]}, expected ~0.835213`);
console.log(`ok: ${n} samples, energy ${energy.toFixed(2)}, peak ${peak}, s[100] ${s[100].toFixed(6)}`);
