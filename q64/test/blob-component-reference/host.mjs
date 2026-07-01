// A generic `q64:blob/store` host that runs the q64-emitted blob component —
// the same role the qubepods host plays. Transpile the component with jco
// (`verify-q64.sh` does this), then this drives it: save/read/drop against a
// real in-memory object store, asserting the canonical-ABI glue (string key,
// list<u8> value, result<option<list<u8>>,error> unwrap for get, result<_,error>
// for put/delete, lazily-opened adapter-held bucket) round-trips.
//
//   node host.mjs <jco-out-dir>   # e.g. node host.mjs ./jcoout
//
// Exits non-zero on any mismatch. The narrow flat-list<u8> interface means the
// host is a plain in-memory map — no wasi:io streams. That is the whole point:
// env.blob is a q64-owned face; the host (not the guest) does any streaming to
// a real blobstore backend.
import { readFileSync } from 'node:fs';

const outDir = process.argv[2] ?? './jcoout';
const { instantiate } = await import(new URL(outDir + '/blobout.component.js', import.meta.url));

const data = new Map(); // key -> Uint8Array (list<u8>)
class Bucket {
  // option<list<u8>>: a Uint8Array for `some`, undefined for `none`.
  get(key) { return data.has(key) ? data.get(key) : undefined; }
  // value arrives as a Uint8Array (list<u8>).
  put(key, value) { data.set(key, new Uint8Array(value)); }
  // idempotent — no error if absent.
  delete(key) { data.delete(key); }
}
const theBucket = new Bucket();

const imports = {
  'q64:blob/store': {
    Bucket,
    error: class {},
    // identity is host-pinned; the qube opens with an empty identifier.
    open: () => theBucket,
  },
};

const getCore = (name) =>
  WebAssembly.compile(readFileSync(new URL(outDir + '/' + name, import.meta.url)));

const inst = await instantiate(getCore, imports);

const dec = (k) => (data.has(k) ? Buffer.from(data.get(k)).toString('utf8') : undefined);
const expect = (label, got, want) => {
  if (got !== want) {
    console.error(`FAIL: ${label} = ${got}, expected ${want}`);
    process.exit(1);
  }
  console.log(`  ${label} -> ${got}`);
};

expect('save', inst.save(), 1n); // put("greeting","hello") -> Ok(())
if (dec('greeting') !== 'hello') {
  console.error(`FAIL: host store 'greeting' = ${JSON.stringify(dec('greeting'))}, expected 'hello'`);
  process.exit(1);
}
expect('read (present)', inst.read(), 5n); // Ok(Some("hello")) -> v.len == 5
expect('drop', inst.drop(), 1n); // delete -> Ok(())
if (data.has('greeting')) {
  console.error('FAIL: host store still has greeting after delete');
  process.exit(1);
}
expect('read (after delete)', inst.read(), -1n); // Ok(None) -> -1
console.log('OK — the q64 blob component runs on a generic q64:blob/store host.');
