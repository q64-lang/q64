// qube.wasm full resolution (entry + transitive dep modules) over a host `read`.
import { readFileSync } from 'node:fs';
import { resolve as pj } from 'node:path';
const enc = new TextEncoder(), dec = new TextDecoder();
const ROOT = new URL('./fixtures/proj', import.meta.url).pathname;
const wasm = readFileSync(new URL('../zig-out/bin/qube-resolve.wasm', import.meta.url));
let inst;
const hostRead = (ptr, len) => {
  const rel = dec.decode(new Uint8Array(inst.exports.memory.buffer, ptr, len));
  let data; try { data = readFileSync(pj(ROOT, rel)); } catch { return 0n; }
  const p = inst.exports.qube_alloc(data.length);
  new Uint8Array(inst.exports.memory.buffer, p, data.length).set(data);
  return (BigInt(p) << 32n) | BigInt(data.length);
};
({ instance: inst } = await WebAssembly.instantiate(wasm, { env: { read: hostRead } }));
const c = enc.encode('.');
const cp = inst.exports.qube_alloc(c.length);
new Uint8Array(inst.exports.memory.buffer, cp, c.length).set(c);
const packed = inst.exports.qube_resolve(cp, c.length);
if (packed === 0n) { console.error('FAIL: resolve returned 0'); process.exit(1); }
const r = JSON.parse(dec.decode(new Uint8Array(inst.exports.memory.buffer, Number(packed>>32n), Number(packed&0xffffffffn))));
const lib = r.modules.find(m => m.name === 'mathlib');
const ok = r.entryPath === 'src/main.q' && r.main.includes('import mathlib')
  && lib && lib.source.includes('answer');  // resolved lib/src/api.q via the dep's manifest entry
console.log(ok ? 'ok   qube.wasm full resolution: entry=src/main.q, module mathlib <- lib/src/api.q (manifest entry, not lib.q)'
               : `FAIL ${JSON.stringify(r)}`);
process.exit(ok ? 0 : 1);
