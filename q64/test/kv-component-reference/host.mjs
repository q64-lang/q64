// A generic `wasi:keyvalue` host that runs the q64-emitted kv component — the
// same role the qubepods Dynamic Worker plays. Transpile the component with jco
// (`verify-q64.sh` does this), then this drives it: bump/read against a real
// in-memory key-value store, asserting the canonical-ABI glue (string key, s64
// delta, result<s64,error> unwrap, lazily-opened adapter-held bucket) round-trips.
//
//   node host.mjs <jco-out-dir>   # e.g. node host.mjs ./jcoout
//
// Exits non-zero on any mismatch. No q64-specific ABI — the imports are the
// stock wasi:keyvalue interfaces, which is the whole point.
import { readFileSync } from 'node:fs';

const outDir = process.argv[2] ?? './jcoout';
const { instantiate } = await import(new URL(outDir + '/kvout.component.js', import.meta.url));

const data = new Map();
class Bucket {}
const theBucket = new Bucket();

const imports = {
  'wasi:keyvalue/store': {
    Bucket,
    Error: class {},
    // identity is host-pinned; the qube opens with an empty identifier.
    open: () => theBucket,
  },
  'wasi:keyvalue/atomics': {
    increment(_bucket, key, delta) {
      const next = (data.get(key) ?? 0n) + delta; // s64 → bigint
      data.set(key, next);
      return next;
    },
  },
};

const getCore = (name) =>
  WebAssembly.compile(readFileSync(new URL(outDir + '/' + name, import.meta.url)));

const inst = await instantiate(getCore, imports);

const expect = (label, got, want) => {
  if (got !== want) {
    console.error(`FAIL: ${label} = ${got}, expected ${want}`);
    process.exit(1);
  }
  console.log(`  ${label} -> ${got}`);
};

expect('read', inst.read(), 0n);
expect('bump', inst.bump(), 1n);
expect('bump', inst.bump(), 2n);
expect('bump', inst.bump(), 3n);
expect('read', inst.read(), 3n); // read does not change the count
if ((data.get('count') ?? 0n) !== 3n) {
  console.error('FAIL: host store count != 3');
  process.exit(1);
}
console.log('OK — the q64 kv component runs on a generic wasi:keyvalue host.');
