import { readFileSync } from 'node:fs';
const bytes = readFileSync(new URL('../zig-out/bin/qube-resolve.wasm', import.meta.url));
const { instance } = await WebAssembly.instantiate(bytes, {});
const { memory, qube_alloc, qube_resolve_entry } = instance.exports;
const enc = new TextEncoder(), dec = new TextDecoder();

function resolveEntry(manifestText) {
  const data = enc.encode(manifestText);
  const ptr = qube_alloc(data.length);
  new Uint8Array(memory.buffer, ptr, data.length).set(data);
  const packed = qube_resolve_entry(ptr, data.length);          // BigInt (u64)
  if (packed === 0n) return null;                                // parse error → host default
  const outPtr = Number(packed >> 32n), outLen = Number(packed & 0xffffffffn);
  return dec.decode(new Uint8Array(memory.buffer, outPtr, outLen));
}

const cases = [
  ['app, default entry',  `{ name: "x", type: "application" }`,                  'src/main.q'],
  ['lib, default entry',  `{ name: "x", type: "library" }`,                      'src/lib.q'],
  ['explicit entry',      `{ name: "x", type: "application", entry: "main.q" }`, 'main.q'],
  ['lib override',        `{ /* c */ name: 'x', type: 'library', entry: "src/api.q", }`, 'src/api.q'],
  ['twin backend',        readFileSync(new URL('./fixtures/lib.qube.json5', import.meta.url),'utf8'), 'src/lib.q'],
  ['twin frontend',       readFileSync(new URL('./fixtures/app.qube.json5', import.meta.url),'utf8'),         'src/main.q'],
];
let ok = true;
for (const [label, m, want] of cases) {
  const got = resolveEntry(m);
  const pass = got === want;
  ok &&= pass;
  console.log(`${pass ? 'ok  ' : 'FAIL'}  ${label.padEnd(20)} -> ${got}${pass ? '' : `  (expected ${want})`}`);
}
process.exit(ok ? 0 : 1);
