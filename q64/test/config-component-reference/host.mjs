// A generic `wasi:config/store` host that runs the q64-emitted config component
// — the role the qubepods host plays. Transpile the component with jco
// (`verify-q64.sh` does this), then this drives it: read a present key and an
// absent key, asserting the canonical-ABI glue (string key,
// result<option<string>,error> unwrap) round-trips.
//
//   node host.mjs <jco-out-dir>   # e.g. node host.mjs ./jcoout
//
// `get` / `get-all` are TOP-LEVEL interface functions (no resource, no `open`),
// so the host is a plain object of functions — the qube never names a store.
import { readFileSync } from 'node:fs';

const outDir = process.argv[2] ?? './jcoout';
const { instantiate } = await import(new URL(outDir + '/cfgout.component.js', import.meta.url));

const config = new Map([['greeting', 'hello']]);

const imports = {
  'wasi:config/store': {
    // option<string>: the value for a present key, undefined for an absent one.
    get: (key) => (config.has(key) ? config.get(key) : undefined),
    // list<tuple<string, string>>: the whole config as (key, value) pairs.
    getAll: () => [...config.entries()],
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

expect('read (greeting=hello)', inst.read(), 5n); // Ok(Some("hello")) -> len 5
expect('missing', inst.missing(), -1n); // Ok(None) -> -1
console.log('OK — the q64 config component runs on a generic wasi:config/store host.');
