// Headless verification of the retained gallery against the real screen.wasm.
// Runs the actual q64-compiled module with a recording host; no WebGPU needed.
import { readFileSync } from 'node:fs';
import { KIND, ATTR, EVENT } from './protocol.js';

const bytes = readFileSync(new URL('./screen.wasm', import.meta.url));

function makeHost() {
  const nodes = new Map();
  nodes.set(0, { id: 0, kind: -1, parent: -1, attrs: new Map(), children: [], handlers: new Map() });
  const opLog = [];
  let pres = 0;
  const face = {
    env: { out: () => {} },
    qview: {
      create: (id, kind, parent) => {
        id = Number(id); kind = Number(kind); parent = Number(parent);
        const p = nodes.get(parent) ?? nodes.get(0);
        nodes.set(id, { id, kind, parent: p.id, attrs: new Map(), children: [], handlers: new Map() });
        p.children.push(id); opLog.push(['create', id, kind]);
      },
      set_attr: (id, attr, value) => { nodes.get(Number(id))?.attrs.set(Number(attr), Number(value)); opLog.push(['set_attr', Number(id), Number(attr), Number(value)]); },
      remove: (id) => { opLog.push(['remove', Number(id)]); },
      on: (id, event, handler) => { nodes.get(Number(id))?.handlers.set(Number(event), Number(handler)); opLog.push(['on', Number(id), Number(event), Number(handler)]); },
      present: () => { pres++; opLog.push(['present']); },
    },
  };
  return { face, nodes, opLog, presents: () => pres };
}

let pass = 0, fail = 0;
const ok = (c, m) => { if (c) pass++; else { fail++; console.log('  FAIL:', m); } };

const h = makeHost();
const { instance } = await WebAssembly.instantiate(bytes, h.face);
instance.exports._start();

// --- the gallery tree (matches screen.q) ---
const expectKind = {
  1: KIND.label, 2: KIND.box, 10: KIND.label, 20: KIND.button, 21: KIND.label,
  30: KIND.checkbox, 40: KIND.switch, 50: KIND.radio, 52: KIND.radio,
  60: KIND.slider, 70: KIND.progress, 80: KIND.dropdown,
};
for (const [id, k] of Object.entries(expectKind))
  ok(h.nodes.get(Number(id))?.kind === k, `node ${id} is ${Object.keys(KIND).find((n) => KIND[n] === k)}`);

// every interactive control wired to press -> its own handler id
for (const id of [20, 30, 40, 50, 52, 60, 80])
  ok(h.nodes.get(id)?.handlers.get(EVENT.press) === id, `node ${id} press -> handler ${id}`);

ok(h.presents() === 1, 'one present() in _start');
ok(h.nodes.get(60).attrs.get(ATTR.value) === 40, 'slider value starts 40');
ok(h.nodes.get(70).attrs.get(ATTR.value) === 40, 'progress mirrors slider start');
ok(h.nodes.get(50).attrs.get(ATTR.selected) === 1, 'radio A selected at start');

// --- per-handler surgical mutations via the on_<id> exports ---
const handlerFires = (id, expectSets) => {
  const fn = instance.exports[`on_${id}`];
  ok(typeof fn === 'function', `export on_${id} exists`);
  const before = h.opLog.length;
  fn(BigInt(id), BigInt(EVENT.press));
  const delta = h.opLog.slice(before);
  ok(delta.filter((o) => o[0] === 'create').length === 0, `on_${id}: no re-create (surgical)`);
  ok(delta.filter((o) => o[0] === 'present').length === 1, `on_${id}: one present`);
  const sets = delta.filter((o) => o[0] === 'set_attr').map((o) => o[1]);
  for (const n of expectSets) ok(sets.includes(n), `on_${id}: mutates node ${n}`);
};

handlerFires(20, [21]);   // button -> taps label
ok(h.nodes.get(21).attrs.get(ATTR.text_id) === 1, 'taps -> 1');
handlerFires(30, [30]);   // checkbox toggles itself
ok(h.nodes.get(30).attrs.get(ATTR.checked) === 0, 'checkbox toggled off');
handlerFires(40, [40]);   // switch toggles itself
ok(h.nodes.get(40).attrs.get(ATTR.checked) === 1, 'switch toggled on');
handlerFires(52, [50, 52]); // radio B selects -> A clears, B sets
ok(h.nodes.get(50).attrs.get(ATTR.selected) === 0 && h.nodes.get(52).attrs.get(ATTR.selected) === 1, 'radio moved to B');
handlerFires(60, [60, 70]); // slider advances -> progress mirrors
ok(h.nodes.get(60).attrs.get(ATTR.value) === 50 && h.nodes.get(70).attrs.get(ATTR.value) === 50, 'slider+progress -> 50');

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
