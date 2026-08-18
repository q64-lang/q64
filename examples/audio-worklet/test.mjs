// Node smoke for the worklet surface: instantiate once, drive many quanta
// through process(), and assert that state persists across calls and the
// output is the expected hot, clipped voice. No browser required. Run
// after `qube build --addr wasm32`:
//
//   node test.mjs
import { readFileSync } from "node:fs";

const bytes = readFileSync(new URL("./target/debug/wasm32/dev.q64.audio_worklet.wasm", import.meta.url));
const { instance } = await WebAssembly.instantiate(bytes, { env: {} });
const ex = instance.exports;

const st = Number(ex.alloc_f32(16n));
const io = Number(ex.alloc_f32(128n));
const ioData = Number(ex.data_of(io));
const args = [0.00458333, 0.000944692, 0.001889384, 0.000944692, -1.911196288, 0.914975055, 1.8, 1.0];

let energy = 0, last = null, changed = false;
for (let q = 0; q < 400; q++) {
  const r = ex.process(st, io, 128n, ...args);
  if (r !== 128n) throw new Error(`process returned ${r}, expected 128`);
  const s = new Float32Array(ex.memory.buffer, ioData, 128);
  for (const x of s) energy += x * x;
  if (last !== null && s[0] !== last) changed = true;
  last = s[0];
}
if (!changed) throw new Error("state did not persist across quanta (phase never advanced)");
if (Math.abs(energy - 33865) > 700) throw new Error(`energy ${energy}, expected ~33865`);
console.log(`ok: 400 quanta, energy ${energy.toFixed(2)}, state persists`);
