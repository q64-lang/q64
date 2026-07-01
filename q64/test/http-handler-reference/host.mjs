// A generic host that drives the q64-emitted @http_handler component — the role
// the qubepods gate/runner plays. Transpile with jco (`verify-q64.sh` does
// this), then this calls the exported handler with a request (method, path,
// body) and checks the returned response string. Proves the canonical-ABI glue
// for a str-in / str-out component EXPORT (the return-area wrapper).
//
//   node host.mjs <jco-out-dir>   # e.g. node host.mjs ./jcoout
import { readFileSync } from 'node:fs';

const outDir = process.argv[2] ?? './jcoout';
const { instantiate } = await import(new URL(outDir + '/httpout.component.js', import.meta.url));

const getCore = (name) =>
  WebAssembly.compile(readFileSync(new URL(outDir + '/' + name, import.meta.url)));

// The handler imports nothing (it only reads its request args).
const inst = await instantiate(getCore, {});

const expect = (label, got, want) => {
  if (got !== want) {
    console.error(`FAIL: ${label} = ${JSON.stringify(got)}, expected ${JSON.stringify(want)}`);
    process.exit(1);
  }
  console.log(`  ${label} -> ${JSON.stringify(got)}`);
};

expect('serve("GET","/users","")', inst.serve('GET', '/users', ''), 'GET /users handled ()');
expect('serve("POST","/x","hi")', inst.serve('POST', '/x', 'hi'), 'POST /x handled (hi)');
console.log('OK — the q64 @http_handler component serves request→response strings.');
