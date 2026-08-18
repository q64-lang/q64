// An honest minimal WCLAP host in node — the conformance check for
// `q64 emit … --wclap` (docs/audio-roadmap.md phase D).
//
// "Honest" is load-bearing: this host discovers everything the way a real
// WCLAP browser host does, and nothing any other way. It reads the
// `clap_entry` global, walks the CLAP structs in guest linear memory,
// calls every callback through `__indirect_function_table`, allocates its
// own blocks (id strings, port info, the clap_process tree, the audio
// buffers) with the plugin's exported `malloc`, and discovers the audio
// ports via the `clap.audio-ports` extension. It never touches the q64
// module's own exports (`alloc_f32`, `process`, …) — a plugin that only
// works when the host cheats is a broken plugin.
//
//   node check.mjs [path/to/voice.wclap.wasm]
import { readFileSync } from "node:fs";

const path = process.argv[2] ?? new URL("./voice.wclap.wasm", import.meta.url);
const bytes = readFileSync(path);
const { instance } = await WebAssembly.instantiate(bytes, {});
const ex = instance.exports;

// ---- the WCLAP ABI surface --------------------------------------------
for (const name of ["clap_entry", "memory", "__indirect_function_table", "malloc", "free"]) {
  if (!(name in ex)) throw new Error(`missing required export: ${name}`);
}
const table = ex.__indirect_function_table;
const before = table.grow(1); // a capped table throws RangeError here
console.log(`ok: table growable (${before} -> ${table.length})`);

const mem = () => new DataView(ex.memory.buffer);
const u32 = (a) => mem().getUint32(a, true);
const i32 = (a) => mem().getInt32(a, true);
const f32arr = (a, n) => new Float32Array(ex.memory.buffer, a, n);
const cstr = (a) => {
  const b = new Uint8Array(ex.memory.buffer);
  let e = a;
  while (b[e] !== 0) e++;
  return new TextDecoder().decode(b.subarray(a, e));
};
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

// ---- entry ------------------------------------------------------------
const entry = ex.clap_entry.value;
const [maj, min, rev] = [u32(entry), u32(entry + 4), u32(entry + 8)];
console.log(`ok: clap_entry @${entry}, clap version ${maj}.${min}.${rev}`);
if (fn(u32(entry + 12))(putStr("/plugin/check")) !== 1) throw new Error("entry.init failed");

const getFactory = fn(u32(entry + 20));
if (getFactory(putStr("clap.bogus-factory")) !== 0) throw new Error("get_factory matched a bogus id");
const factory = getFactory(putStr("clap.plugin-factory"));
if (factory === 0) throw new Error("get_factory(clap.plugin-factory) returned null");

// ---- factory / descriptor --------------------------------------------
const count = fn(u32(factory))(factory);
if (count !== 1) throw new Error(`plugin count ${count}, expected 1`);
const desc = fn(u32(factory + 4))(factory, 0);
if (desc === 0) throw new Error("get_plugin_descriptor(0) returned null");
if (fn(u32(factory + 4))(factory, 1) !== 0) throw new Error("descriptor index 1 should be null");
const id = cstr(u32(desc + 12));
console.log(`ok: descriptor id="${id}" name="${cstr(u32(desc + 16))}" vendor="${cstr(u32(desc + 20))}" version="${cstr(u32(desc + 36))}"`);
const features = [];
for (let f = u32(desc + 44); u32(f) !== 0; f += 4) features.push(cstr(u32(f)));
console.log(`ok: features [${features.join(", ")}]`);

const plugin = fn(u32(factory + 8))(factory, 0, putStr(id));
if (plugin === 0) throw new Error("create_plugin returned null");

// ---- plugin lifecycle -------------------------------------------------
const P = {
  init: fn(u32(plugin + 8)), destroy: fn(u32(plugin + 12)),
  activate: fn(u32(plugin + 16)), deactivate: fn(u32(plugin + 20)),
  start: fn(u32(plugin + 24)), stop: fn(u32(plugin + 28)),
  process: fn(u32(plugin + 36)), getExt: fn(u32(plugin + 40)),
};
if (P.init(plugin) !== 1) throw new Error("plugin.init failed");

// ---- clap.audio-ports: the only legitimate way to learn the buses -----
if (P.getExt(plugin, putStr("clap.bogus-ext")) !== 0) throw new Error("get_extension matched a bogus id");
const portsExt = P.getExt(plugin, putStr("clap.audio-ports"));
if (portsExt === 0) throw new Error("no clap.audio-ports extension — a real host would allocate no buffers (dead silent plugin)");
const portsCount = fn(u32(portsExt));
const portsGet = fn(u32(portsExt + 4));
const nIn = portsCount(plugin, 1);
const nOut = portsCount(plugin, 0);
if (nOut !== 1) throw new Error(`output port count ${nOut}, expected 1`);
const info = ex.malloc(276); // clap_audio_port_info
if (portsGet(plugin, 0, 0, info) !== 1) throw new Error("audio_ports.get(0, output) failed");
if (portsGet(plugin, 1, 0, info) === 1) throw new Error("audio_ports.get(1) should fail");
const channels = u32(info + 264);
console.log(`ok: ports in=${nIn} out=${nOut}, port 0 "${cstr(info + 4)}" channels=${channels} type="${cstr(u32(info + 268))}" flags=${u32(info + 260)} pair=${i32(info + 272)}`);
if (channels < 1 || channels > 8) throw new Error(`implausible channel count ${channels}`);

// ---- clap.params ------------------------------------------------------
const paramsExt = P.getExt(plugin, putStr("clap.params"));
if (paramsExt === 0) throw new Error("no clap.params extension");
const PR = {
  count: fn(u32(paramsExt)), info: fn(u32(paramsExt + 4)),
  get: fn(u32(paramsExt + 8)), v2t: fn(u32(paramsExt + 12)),
  t2v: fn(u32(paramsExt + 16)), flush: fn(u32(paramsExt + 20)),
};
const nParams = PR.count(plugin);
if (nParams !== 2) throw new Error(`param count ${nParams}, expected 2`);
const pinfo = ex.malloc(1320); // clap_param_info
const readInfo = (i) => {
  if (PR.info(plugin, i, pinfo) !== 1) throw new Error(`get_info(${i}) failed`);
  return {
    id: u32(pinfo), flags: u32(pinfo + 4), name: cstr(pinfo + 12), module: cstr(pinfo + 268),
    min: mem().getFloat64(pinfo + 1296, true), max: mem().getFloat64(pinfo + 1304, true),
    def: mem().getFloat64(pinfo + 1312, true),
  };
};
const freqInfo = readInfo(0), driveInfo = readInfo(1);
if (PR.info(plugin, 2, pinfo) !== 0) throw new Error("get_info(2) should fail");
for (const [p, want] of [[freqInfo, { id: 0, name: "Frequency", min: 20, max: 2000, def: 110 }], [driveInfo, { id: 1, name: "Drive", min: 1, max: 4, def: 1.8 }]]) {
  for (const [k, v] of Object.entries(want)) {
    if (p[k] !== v) throw new Error(`param "${p.name}": ${k}=${p[k]}, expected ${v}`);
  }
  if (!(p.flags & (1 << 5))) throw new Error(`param "${p.name}" not CLAP_PARAM_IS_AUTOMATABLE`);
}
console.log(`ok: params [${freqInfo.name} ${freqInfo.min}..${freqInfo.max} def ${freqInfo.def}] [${driveInfo.name} ${driveInfo.min}..${driveInfo.max} def ${driveInfo.def}]`);

const pval = ex.malloc(8);
const getValue = (id) => {
  if (PR.get(plugin, id, pval) !== 1) throw new Error(`get_value(${id}) failed`);
  return mem().getFloat64(pval, true);
};
if (getValue(0) !== 110) throw new Error(`freq default ${getValue(0)}, expected 110`);
if (getValue(1) !== 1.8) throw new Error(`drive default ${getValue(1)}, expected 1.8`);
if (PR.get(plugin, 7, pval) !== 0) throw new Error("get_value(7) should fail");
if (PR.v2t(plugin, 0, 123.0, ex.malloc(32), 32) !== 0) throw new Error("value_to_text should return false (host formats)");
if (PR.t2v(plugin, putStr("123"), pval) !== 0) throw new Error("text_to_value should return false");

// ---- host event-list trampolines --------------------------------------
// The clap_input_events size/get members are HOST functions. A wasm host
// installs them by growing the plugin's table and setting real wasm
// funcrefs — a JS function can't enter a funcref table directly, so we
// compile a tiny trampoline module per signature (import env.f, export
// it), exactly what wclap-host-js does. This is the mechanism the
// growable table exists for.
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
let pendingEvents = []; // addresses of clap_event_param_value blocks
const sizeIdx = table.grow(1);
table.set(sizeIdx, trampoline(() => pendingEvents.length, 1));
const getIdx = table.grow(1);
table.set(getIdx, trampoline((_list, i) => pendingEvents[i] ?? 0, 2));
const inEvents = ex.malloc(12); // clap_input_events {ctx, size, get}
mem().setUint32(inEvents + 0, 0, true);
mem().setUint32(inEvents + 4, sizeIdx, true);
mem().setUint32(inEvents + 8, getIdx, true);
const paramEvent = (id, value) => {
  const ev = ex.malloc(48); // clap_event_param_value
  mem().setUint32(ev + 0, 48, true); // header.size
  mem().setUint32(ev + 4, 0, true); // time
  mem().setUint16(ev + 8, 0, true); // CLAP_CORE_EVENT_SPACE_ID
  mem().setUint16(ev + 10, 5, true); // CLAP_EVENT_PARAM_VALUE
  mem().setUint32(ev + 12, 0, true); // flags
  mem().setUint32(ev + 16, id, true);
  mem().setUint32(ev + 20, 0, true); // cookie
  mem().setInt32(ev + 24, -1, true); // note_id
  mem().setInt16(ev + 28, -1, true); // port_index
  mem().setInt16(ev + 30, -1, true); // channel
  mem().setInt16(ev + 32, -1, true); // key
  mem().setFloat64(ev + 40, value, true);
  return ev;
};

// ---- activate + process ----------------------------------------------
const FRAMES = 128, SR = 48000;
if (P.activate(plugin, SR, 32, FRAMES) !== 1) throw new Error("activate failed");
if (P.start(plugin) !== 1) throw new Error("start_processing failed");

// The host builds the clap_process tree in plugin memory, sized from what
// audio-ports reported — exactly like the browser host does.
const chBufs = Array.from({ length: channels }, () => ex.malloc(FRAMES * 4));
const chArr = ex.malloc(channels * 4);
chBufs.forEach((p, i) => mem().setUint32(chArr + 4 * i, p, true));
const outBuf = ex.malloc(24); // clap_audio_buffer
mem().setUint32(outBuf + 0, chArr, true); // data32
mem().setUint32(outBuf + 4, 0, true); // data64
mem().setUint32(outBuf + 8, channels, true);
mem().setUint32(outBuf + 12, 0, true); // latency
const proc = ex.malloc(40); // clap_process
mem().setBigInt64(proc + 0, 0n, true); // steady_time
mem().setUint32(proc + 8, FRAMES, true);
mem().setUint32(proc + 12, 0, true); // transport
mem().setUint32(proc + 16, 0, true); // audio_inputs
mem().setUint32(proc + 20, outBuf, true);
mem().setUint32(proc + 24, 0, true); // in_count
mem().setUint32(proc + 28, 1, true); // out_count
mem().setUint32(proc + 32, inEvents, true); // in_events (host trampolines)
mem().setUint32(proc + 36, 0, true); // out_events

let last = null, changed = false, stereoOk = true;
const runBlocks = (n) => {
  const samples = new Float32Array(n * FRAMES);
  for (let q = 0; q < n; q++) {
    const status = P.process(plugin, proc);
    pendingEvents = []; // events are consumed by the block they arrive with
    if (status !== 1) throw new Error(`process returned ${status}, expected CLAP_PROCESS_CONTINUE`);
    const ch0 = f32arr(chBufs[0], FRAMES);
    for (const x of ch0) if (!Number.isFinite(x)) throw new Error("non-finite sample");
    if (channels > 1) {
      const ch1 = f32arr(chBufs[1], FRAMES);
      for (let i = 0; i < FRAMES; i++) if (ch0[i] !== ch1[i]) { stereoOk = false; break; }
    }
    if (last !== null && ch0[0] !== last) changed = true;
    last = ch0[0];
    samples.set(ch0, q * FRAMES);
  }
  return samples;
};
// Fundamental period from rising zero-crossings (the low-pass smears the
// saw's wrap across ~sr/cutoff samples, so edge detection won't work, but
// the filtered wave still crosses zero once per direction per cycle).
const measurePeriod = (samples) => {
  const crossings = [];
  for (let i = 1; i < samples.length; i++) if (samples[i - 1] < 0 && samples[i] >= 0) crossings.push(i);
  if (crossings.length < 3) throw new Error(`too few zero-crossings (${crossings.length}) to measure pitch`);
  return (crossings[crossings.length - 1] - crossings[0]) / (crossings.length - 1);
};

const BLOCKS = 400;
const base = runBlocks(BLOCKS);
let energy = 0;
for (const x of base) energy += x * x;
if (energy < 1) throw new Error("plugin is silent — audio never reached the host buffers");
if (!changed) throw new Error("state did not persist across process calls (phase never advanced)");
if (!stereoOk) throw new Error("channel 1 diverged from channel 0");
// Same voice as examples/audio-worklet at 110 Hz: ~84.7 energy per block.
const perBlock = energy / BLOCKS;
if (Math.abs(perBlock - 84.7) > 8) throw new Error(`per-block energy ${perBlock.toFixed(2)}, expected ~84.7`);
const basePeriod = measurePeriod(base.subarray(base.length / 2));
if (Math.abs(basePeriod - SR / 110) > SR / 110 * 0.1) throw new Error(`baseline period ${basePeriod.toFixed(1)} samples, expected ~${(SR / 110).toFixed(1)} (110 Hz)`);
console.log(`ok: ${BLOCKS} blocks, energy ${perBlock.toFixed(2)}/block, period ${basePeriod.toFixed(1)} samples (~${(SR / basePeriod).toFixed(1)} Hz), state persists, stereo mirrored`);

// ---- automation: a param event through process must change the sound --
pendingEvents = [paramEvent(0, 220)];
runBlocks(40); // let the in-guest one-pole smoothing settle
if (getValue(0) !== 220) throw new Error(`freq after event ${getValue(0)}, expected 220`);
const shifted = measurePeriod(runBlocks(40));
if (Math.abs(shifted - SR / 220) > SR / 220 * 0.1) throw new Error(`post-automation period ${shifted.toFixed(1)} samples, expected ~${(SR / 220).toFixed(1)} (220 Hz)`);
console.log(`ok: param event freq=220 -> period ${shifted.toFixed(1)} samples (~${(SR / shifted).toFixed(1)} Hz)`);

// ---- flush + clamping -------------------------------------------------
// flush applies events outside processing; out-of-range values clamp.
pendingEvents = [paramEvent(1, 3.0), paramEvent(0, 99999)];
PR.flush(plugin, inEvents, 0);
pendingEvents = [];
if (getValue(1) !== 3.0) throw new Error(`drive after flush ${getValue(1)}, expected 3.0`);
if (getValue(0) !== 2000) throw new Error(`freq after out-of-range flush ${getValue(0)}, expected clamp to 2000`);
console.log("ok: flush applies events, out-of-range values clamp");

P.stop(plugin);
P.deactivate(plugin);
P.destroy(plugin);
fn(u32(entry + 16))(); // entry.deinit
console.log("wclap-check: PASS");
