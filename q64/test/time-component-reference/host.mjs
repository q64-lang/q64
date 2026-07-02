// A generic `wasi:clocks/monotonic-clock` host that runs the q64-emitted time
// component — the role the qubepods host plays. Transpile the component with
// jco (`verify-q64.sh` does this), then this drives it: read the clock and an
// elapsed span, asserting the bare-scalar canonical-ABI glue (a nullary `now`
// returning u64, no memory involvement) round-trips.
//
//   node host.mjs <jco-out-dir>   # e.g. node host.mjs ./jcoout
//
// `now` is a TOP-LEVEL interface function returning a bare scalar, so the host
// is one function — the qube never sees more than the instant it asked for.
import { readFileSync } from 'node:fs';
import { hrtime } from 'node:process';

const outDir = process.argv[2] ?? './jcoout';
const { instantiate } = await import(new URL(outDir + '/timeout.component.js', import.meta.url));

const imports = {
  'wasi:clocks/monotonic-clock': {
    // instant (u64): nanoseconds from an arbitrary, fixed origin — carried
    // as a BigInt (the `n` suffix on its values) because ns counts overflow
    // a JS Number's exact-integer range (2^53-1 ns is only ~104 days).
    now: () => hrtime.bigint(),
    // duration (u64): this host's tick size — 1ns, hrtime's unit.
    resolution: () => 1n,
  },
  'wasi:clocks/wall-clock': {
    // datetime record: seconds (u64) + nanoseconds (u32) since the epoch.
    now: () => {
      const ms = Date.now();
      return { seconds: BigInt(Math.floor(ms / 1000)), nanoseconds: (ms % 1000) * 1_000_000 };
    },
  },
};

const getCore = (name) =>
  WebAssembly.compile(readFileSync(new URL(outDir + '/' + name, import.meta.url)));

const inst = await instantiate(getCore, imports);

const a = inst.mono();
const b = inst.mono();
if (typeof a !== 'bigint' || a <= 0n) {
  console.error(`FAIL: mono() = ${a}, expected a positive bigint instant`);
  process.exit(1);
}
if (b < a) {
  console.error(`FAIL: mono() went backwards (${a} -> ${b})`);
  process.exit(1);
}
console.log(`  mono() -> ${a} then ${b} (monotonic ✓)`);

const d = inst.delta();
if (typeof d !== 'bigint' || d < 0n) {
  console.error(`FAIL: delta() = ${d}, expected a non-negative bigint span`);
  process.exit(1);
}
console.log(`  delta() -> ${d} ns between two in-qube readings`);

const r = inst.resolution();
if (r !== 1n) {
  console.error(`FAIL: resolution() = ${r}, host advertised 1n`);
  process.exit(1);
}
console.log(`  resolution() -> ${r} ns per tick`);

// unix() folds the datetime record to epoch-ns in-qube; compare against the
// host's own clock with a generous minute of slack.
const u = inst.unix();
const nowNs = BigInt(Date.now()) * 1_000_000n;
const diff = u > nowNs ? u - nowNs : nowNs - u;
if (typeof u !== 'bigint' || diff > 60_000_000_000n) {
  console.error(`FAIL: unix() = ${u}, host says ~${nowNs}`);
  process.exit(1);
}
console.log(`  unix() -> ${u} ns since the epoch (host agrees ±${diff} ns)`);
console.log('OK — the q64 time component runs on a generic wasi:clocks host.');
