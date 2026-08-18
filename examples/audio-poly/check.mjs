// Conformance check for the polyphonic plugin convention — the same
// honest-host rules as examples/audio-wclap/check.mjs (which owns the
// full static-surface checks); this one proves the *notes-in-guest*
// path: silence until a note, chords, independent voice release, and
// voice stealing — all measured in the rendered audio.
//
//   node check.mjs [path/to/poly.wclap.wasm]
import { readFileSync } from "node:fs";

const path = process.argv[2] ?? new URL("./poly.wclap.wasm", import.meta.url);
const { instance } = await WebAssembly.instantiate(readFileSync(path), {});
const ex = instance.exports;

const table = ex.__indirect_function_table;
table.grow(1);
const mem = () => new DataView(ex.memory.buffer);
const u32 = (a) => mem().getUint32(a, true);
const f32arr = (a, n) => new Float32Array(ex.memory.buffer, a, n);
const putStr = (s) => {
  const enc = new TextEncoder().encode(s);
  const p = ex.malloc(enc.length + 1);
  new Uint8Array(ex.memory.buffer).set(enc, p);
  new Uint8Array(ex.memory.buffer)[p + enc.length] = 0;
  return p;
};
const fn = (idx) => {
  const f = table.get(idx);
  if (!f) throw new Error(`null function pointer (table index ${idx})`);
  return f;
};

// ---- lifecycle --------------------------------------------------------
const entry = ex.clap_entry.value;
if (fn(u32(entry + 12))(putStr("/plugin/poly")) !== 1) throw new Error("entry.init failed");
const factory = fn(u32(entry + 20))(putStr("clap.plugin-factory"));
const plugin = fn(u32(factory + 8))(factory, 0, putStr("dev.q64.poly"));
const P = {
  init: fn(u32(plugin + 8)), activate: fn(u32(plugin + 16)),
  start: fn(u32(plugin + 24)), process: fn(u32(plugin + 36)),
  getExt: fn(u32(plugin + 40)),
};
if (P.init(plugin) !== 1) throw new Error("plugin.init failed");
if (P.getExt(plugin, putStr("clap.audio-ports")) === 0) throw new Error("no clap.audio-ports");
if (P.getExt(plugin, putStr("clap.params")) === 0) throw new Error("no clap.params");
const FRAMES = 128, SR = 48000;
if (P.activate(plugin, SR, 32, FRAMES) !== 1) throw new Error("activate failed");
if (P.start(plugin) !== 1) throw new Error("start failed");

// ---- host event trampolines + clap_process ---------------------------
const trampoline = (js, nArgs) => {
  const sec = (id, content) => [id, content.length, ...content];
  const body = [0, ...Array.from({ length: nArgs }, (_, i) => [0x20, i]).flat(), 0x10, 0x00, 0x0b];
  const bytes = new Uint8Array([
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    ...sec(1, [1, 0x60, nArgs, ...Array(nArgs).fill(0x7f), 1, 0x7f]),
    ...sec(2, [1, 3, 0x65, 0x6e, 0x76, 1, 0x66, 0x00, 0x00]),
    ...sec(3, [1, 0x00]),
    ...sec(7, [1, 1, 0x74, 0x00, 0x01]),
    ...sec(10, [1, body.length, ...body]),
  ]);
  return new WebAssembly.Instance(new WebAssembly.Module(bytes), { env: { f: js } }).exports.t;
};
let pendingEvents = [];
const sizeIdx = table.grow(1);
table.set(sizeIdx, trampoline(() => pendingEvents.length, 1));
const getIdx = table.grow(1);
table.set(getIdx, trampoline((_l, i) => pendingEvents[i] ?? 0, 2));
const inEvents = ex.malloc(12);
mem().setUint32(inEvents + 4, sizeIdx, true);
mem().setUint32(inEvents + 8, getIdx, true);
const noteEvent = (type, key, velocity) => {
  const ev = ex.malloc(40);
  mem().setUint32(ev + 0, 40, true);
  mem().setUint16(ev + 10, type, true);
  mem().setInt16(ev + 24, key, true);
  mem().setFloat64(ev + 32, velocity, true);
  return ev;
};

const ch0 = ex.malloc(FRAMES * 4), ch1 = ex.malloc(FRAMES * 4);
const chArr = ex.malloc(8);
mem().setUint32(chArr, ch0, true);
mem().setUint32(chArr + 4, ch1, true);
const outBuf = ex.malloc(24);
mem().setUint32(outBuf + 0, chArr, true);
mem().setUint32(outBuf + 8, 2, true);
const proc = ex.malloc(40);
mem().setUint32(proc + 8, FRAMES, true);
mem().setUint32(proc + 20, outBuf, true);
mem().setUint32(proc + 28, 1, true);
mem().setUint32(proc + 32, inEvents, true);

const runBlocks = (n) => {
  const samples = new Float32Array(n * FRAMES);
  for (let q = 0; q < n; q++) {
    if (P.process(plugin, proc) !== 1) throw new Error("process != CONTINUE");
    pendingEvents = [];
    const s = f32arr(ch0, FRAMES);
    for (const x of s) if (!Number.isFinite(x)) throw new Error("non-finite sample");
    samples.set(s, q * FRAMES);
  }
  return samples;
};
const rms = (s) => Math.sqrt(s.reduce((a, x) => a + x * x, 0) / s.length);
const measurePeriod = (samples) => {
  const c = [];
  for (let i = 1; i < samples.length; i++) if (samples[i - 1] < 0 && samples[i] >= 0) c.push(i);
  if (c.length < 3) throw new Error(`too few zero-crossings (${c.length})`);
  return (c[c.length - 1] - c[0]) / (c.length - 1);
};
const expectPeriod = (got, hz, what) => {
  const want = SR / hz;
  if (Math.abs(got - want) > want * 0.1) throw new Error(`${what}: period ${got.toFixed(1)}, expected ~${want.toFixed(1)} (${hz} Hz)`);
};

// ---- the poly behaviors ----------------------------------------------
// A note-handling guest is silent until a note arrives (no free-run).
if (rms(runBlocks(20)) > 1e-6) throw new Error("poly synth not silent before any note");
console.log("ok: silent before the first note");

pendingEvents = [noteEvent(0, 69, 1.0)];
runBlocks(40);
const single = runBlocks(40);
expectPeriod(measurePeriod(single), 440, "single note A4");
const singleRms = rms(single);

// A second note is a chord: energy rises (modestly — the soft clipper
// compresses the mix and the low-pass attenuates E5's spectrum; the
// real independence proof is the release test below).
pendingEvents = [noteEvent(0, 76, 1.0)]; // E5, 659.26 Hz
runBlocks(40);
const chord = runBlocks(40);
const chordRms = rms(chord);
if (chordRms < singleRms * 1.05) throw new Error(`chord rms ${chordRms.toFixed(4)} not above single ${singleRms.toFixed(4)}`);
console.log(`ok: chord — rms ${singleRms.toFixed(3)} -> ${chordRms.toFixed(3)}`);

// Releasing one voice leaves the OTHER still sounding at its own pitch —
// the proof the voices are independent.
pendingEvents = [noteEvent(1, 69, 0.0)];
runBlocks(60);
const remaining = runBlocks(40);
expectPeriod(measurePeriod(remaining), 659.26, "remaining voice E5");
console.log("ok: released A4, E5 keeps sounding at its own pitch");

pendingEvents = [noteEvent(1, 76, 0.0)];
runBlocks(60);
if (rms(runBlocks(10)) > 1e-3) throw new Error("not silent after releasing all notes");
console.log("ok: all released -> silence");

// Voice stealing: 10 notes on 8 voices, then release all 10 — nothing
// may stick.
pendingEvents = Array.from({ length: 10 }, (_, i) => noteEvent(0, 48 + i * 3, 1.0));
runBlocks(40);
if (rms(runBlocks(10)) < 0.01) throw new Error("10-note cluster is silent");
pendingEvents = Array.from({ length: 10 }, (_, i) => noteEvent(1, 48 + i * 3, 0.0));
runBlocks(80);
const tail = rms(runBlocks(10));
if (tail > 1e-3) throw new Error(`voice stuck after mass release (rms ${tail})`);
console.log("ok: 10 notes on 8 voices, mass release -> silence (stealing works)");

console.log("poly-check: PASS");
