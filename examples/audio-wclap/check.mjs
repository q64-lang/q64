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
mem().setUint32(proc + 32, 0, true); // in_events
mem().setUint32(proc + 36, 0, true); // out_events

const BLOCKS = 400;
let energy = 0, last = null, changed = false, stereoOk = true;
for (let q = 0; q < BLOCKS; q++) {
  const status = P.process(plugin, proc);
  if (status !== 1) throw new Error(`process returned ${status}, expected CLAP_PROCESS_CONTINUE`);
  const ch0 = f32arr(chBufs[0], FRAMES);
  for (const x of ch0) {
    if (!Number.isFinite(x)) throw new Error("non-finite sample");
    energy += x * x;
  }
  if (channels > 1) {
    const ch1 = f32arr(chBufs[1], FRAMES);
    for (let i = 0; i < FRAMES; i++) if (ch0[i] !== ch1[i]) { stereoOk = false; break; }
  }
  if (last !== null && ch0[0] !== last) changed = true;
  last = ch0[0];
}
if (energy < 1) throw new Error("plugin is silent — audio never reached the host buffers");
if (!changed) throw new Error("state did not persist across process calls (phase never advanced)");
if (!stereoOk) throw new Error("channel 1 diverged from channel 0");
// Same voice as examples/audio-worklet at 110 Hz: ~84.7 energy per block.
const perBlock = energy / BLOCKS;
if (Math.abs(perBlock - 84.7) > 8) throw new Error(`per-block energy ${perBlock.toFixed(2)}, expected ~84.7`);

P.stop(plugin);
P.deactivate(plugin);
P.destroy(plugin);
fn(u32(entry + 16))(); // entry.deinit
console.log(`ok: ${BLOCKS} blocks processed, energy ${energy.toFixed(2)} (${perBlock.toFixed(2)}/block), state persists, stereo mirrored`);
console.log("wclap-check: PASS");
