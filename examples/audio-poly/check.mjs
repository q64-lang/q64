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
const paramsExt = P.getExt(plugin, putStr("clap.params"));
if (paramsExt === 0) throw new Error("no clap.params");
const FRAMES = 128, SR = 48000;
if (P.activate(plugin, SR, 32, FRAMES) !== 1) throw new Error("activate failed");
if (P.start(plugin) !== 1) throw new Error("start failed");

// ---- the GUEST-declared parameter table -------------------------------
// The shim holds no parameter knowledge here — every answer below is the
// shim calling back into the guest's param_* exports.
const cstr = (a) => {
  const b = new Uint8Array(ex.memory.buffer);
  let e = a;
  while (b[e] !== 0) e++;
  return new TextDecoder().decode(b.subarray(a, e));
};
const PR = {
  count: fn(u32(paramsExt)), info: fn(u32(paramsExt + 4)),
  get: fn(u32(paramsExt + 8)),
};
if (PR.count(plugin) !== 2) throw new Error(`param count ${PR.count(plugin)}, expected 2`);
const pinfo = ex.malloc(1320);
const readInfo = (i) => {
  if (PR.info(plugin, i, pinfo) !== 1) throw new Error(`get_info(${i}) failed`);
  return {
    id: u32(pinfo), flags: u32(pinfo + 4), name: cstr(pinfo + 12),
    min: mem().getFloat64(pinfo + 1296, true), max: mem().getFloat64(pinfo + 1304, true),
    def: mem().getFloat64(pinfo + 1312, true),
  };
};
const cut = readInfo(0), drv = readInfo(1);
for (const [p, want] of [[cut, { id: 0, name: "Cutoff", min: 100, max: 8000, def: 1000 }], [drv, { id: 1, name: "Drive", min: 1, max: 4, def: 1.8 }]]) {
  for (const [k, v] of Object.entries(want)) {
    if (p[k] !== v) throw new Error(`param "${p.name}": ${k}=${p[k]}, expected ${v}`);
  }
  if (!(p.flags & (1 << 5))) throw new Error(`param "${p.name}" not automatable`);
}
if (PR.info(plugin, 2, pinfo) !== 0) throw new Error("get_info(2) should fail");
const pval = ex.malloc(8);
const getValue = (id) => {
  if (PR.get(plugin, id, pval) !== 1) throw new Error(`get_value(${id}) failed`);
  return mem().getFloat64(pval, true);
};
if (getValue(0) !== 1000) throw new Error(`cutoff default ${getValue(0)}, expected 1000`);
if (Math.abs(getValue(1) - 1.8) > 1e-6) throw new Error(`drive default ${getValue(1)}, expected 1.8`);
if (PR.get(plugin, 5, pval) !== 0) throw new Error("get_value(5) should fail");
console.log(`ok: guest params — [${cut.name} ${cut.min}..${cut.max} def ${cut.def}] [${drv.name} ${drv.min}..${drv.max} def ${drv.def.toFixed(1)}]`);

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
const noteEvent = (type, key, velocity, time = 0) => {
  const ev = ex.malloc(40);
  mem().setUint32(ev + 0, 40, true);
  mem().setUint32(ev + 4, time, true); // sample offset within the block
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

// ---- the cutoff parameter must change the SOUND ----------------------
// Param events route through the guest's set_param, which computes RBJ
// low-pass coefficients in q64 (sin2pi/cos2pi). Brightness = RMS of the
// first difference over RMS — a high cutoff keeps the saw's edges, a low
// one rounds them off.
const paramEvent = (id, value) => {
  const ev = ex.malloc(48); // clap_event_param_value
  mem().setUint32(ev + 0, 48, true);
  mem().setUint16(ev + 10, 5, true);
  mem().setUint32(ev + 16, id, true);
  mem().setFloat64(ev + 40, value, true);
  return ev;
};
const brightness = (s) => {
  let d = 0, t = 0;
  for (let i = 1; i < s.length; i++) { d += (s[i] - s[i - 1]) ** 2; t += s[i] * s[i]; }
  return Math.sqrt(d / t);
};
pendingEvents = [noteEvent(0, 57, 1.0), paramEvent(0, 8000)];
runBlocks(60);
if (getValue(0) !== 8000) throw new Error(`cutoff after event ${getValue(0)}, expected 8000`);
const bright = brightness(runBlocks(40));
pendingEvents = [paramEvent(0, 200)];
runBlocks(60);
if (getValue(0) !== 200) throw new Error(`cutoff after event ${getValue(0)}, expected 200`);
const dark = brightness(runBlocks(40));
if (bright / dark < 2) throw new Error(`cutoff sweep changed brightness only ${(bright / dark).toFixed(2)}x (want > 2x)`);
pendingEvents = [paramEvent(0, 99999)];
runBlocks(2);
if (getValue(0) !== 8000) throw new Error(`out-of-range cutoff ${getValue(0)}, expected guest clamp to 8000`);
pendingEvents = [noteEvent(1, 57, 0.0)];
runBlocks(60);
console.log(`ok: cutoff is audible — brightness ${dark.toFixed(3)} @200 Hz -> ${bright.toFixed(3)} @8 kHz (${(bright / dark).toFixed(1)}x), guest clamps out-of-range`);

// ---- raw MIDI (type 10): mod wheel -> cutoff -------------------------
// The shim forwards the 3 data bytes to the guest `midi` export; the
// guest maps CC 1 through its own set_param. Verified via the params
// extension readback (the same value a DAW's UI would show).
const midiEvent = (b0, b1, b2) => {
  const ev = ex.malloc(24); // clap_event_midi
  mem().setUint32(ev + 0, 24, true);
  mem().setUint16(ev + 10, 10, true); // CLAP_EVENT_MIDI
  mem().setUint16(ev + 16, 0, true); // port_index
  new Uint8Array(ex.memory.buffer).set([b0, b1, b2], ev + 18);
  return ev;
};
pendingEvents = [midiEvent(0xb0, 1, 127)]; // mod wheel full
runBlocks(2);
const wheelFull = getValue(0);
if (Math.abs(wheelFull - (100 + 127 * 62.2)) > 1) throw new Error(`CC1=127 cutoff ${wheelFull}, expected ~${100 + 127 * 62.2}`);
pendingEvents = [midiEvent(0xb0, 1, 0)]; // mod wheel zero
runBlocks(2);
if (getValue(0) !== 100) throw new Error(`CC1=0 cutoff ${getValue(0)}, expected 100`);
pendingEvents = [midiEvent(0xb0, 7, 64)]; // CC 7 (volume) — must be ignored
runBlocks(2);
if (getValue(0) !== 100) throw new Error("unmapped CC changed the cutoff");
console.log(`ok: raw MIDI — mod wheel sweeps cutoff (127 -> ${wheelFull.toFixed(1)} Hz, 0 -> 100 Hz), unmapped CC ignored`);

// ---- sample-offset accuracy ------------------------------------------
// A note-on carrying time=64 must leave the first 64 samples of that
// block EXACTLY zero (the trampoline renders [0,64) before applying the
// event, and a silent poly guest renders exact zeros) and produce sound
// in [64,128). Block-snapped handling would ramp from sample 0 — this
// boundary is the sharpest possible proof the time field is honored.
pendingEvents = [noteEvent(0, 69, 1.0, 64)];
const offsetBlock = runBlocks(1);
for (let i = 0; i < 64; i++) {
  if (offsetBlock[i] !== 0) throw new Error(`sample ${i} nonzero (${offsetBlock[i]}) before the time=64 note-on`);
}
let after = 0;
for (let i = 64; i < FRAMES; i++) after += Math.abs(offsetBlock[i]);
if (after === 0) throw new Error("no audio after the time=64 note-on within its block");
pendingEvents = [noteEvent(1, 69, 0.0)];
runBlocks(60);
console.log("ok: sample-offset accuracy — time=64 note-on: [0,64) exactly zero, [64,128) sounding");

console.log("poly-check: PASS");
