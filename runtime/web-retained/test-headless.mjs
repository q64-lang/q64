// Headless verification of the retained protocol against the real screen.wasm.
// Runs the actual q64-compiled module with a recording host; no WebGPU needed.
import { readFileSync } from 'node:fs';
import { KIND, ATTR, EVENT } from './protocol.js';

const bytes = readFileSync(new URL('./screen.wasm', import.meta.url));

// A minimal retained tree applying the five ops (mirrors app.js, sans GPU).
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
        p.children.push(id); opLog.push(['create', id, kind, parent]);
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
const ok = (c, m) => { if (c) { pass++; } else { fail++; console.log('  FAIL:', m); } };

const h = makeHost();
const { instance } = await WebAssembly.instantiate(bytes, h.face);
instance.exports._start();

// --- assertions on the built tree (matches runtime/web-retained/screen.q) ---
ok(h.nodes.has(1) && h.nodes.get(1).kind === KIND.label, 'node 1 is a label');
ok(h.nodes.has(2) && h.nodes.get(2).kind === KIND.label, 'node 2 is a label');
ok(h.nodes.has(3) && h.nodes.get(3).kind === KIND.button, 'node 3 is a button');
ok(h.nodes.get(3).parent === 0, 'button parented to root');
ok(h.nodes.get(3).attrs.get(ATTR.w) === 280, 'button width=280');
ok(h.nodes.get(3).attrs.get(ATTR.radius) === 16, 'button radius=16');
ok(h.nodes.get(3).handlers.get(EVENT.press) === 1, 'button press wired to handler 1');
ok(h.nodes.get(2).attrs.get(ATTR.text_id) === 0, 'count label starts at 0');
ok(h.presents() === 1, 'exactly one present() in _start');

// --- the surgical mutation: on_event must emit ONE set_attr + one present ----
const before = h.opLog.length;
instance.exports.on_event(3n, BigInt(EVENT.press));
const delta = h.opLog.slice(before);
const sets = delta.filter((o) => o[0] === 'set_attr');
const pres = delta.filter((o) => o[0] === 'present');
ok(sets.length === 1 && sets[0][1] === 2 && sets[0][2] === ATTR.text_id, 'on_event emits exactly set_attr on node 2 text_id');
ok(sets[0][3] === 1, 'count incremented to 1');
ok(pres.length === 1, 'on_event presents exactly once');
ok(delta.filter((o) => o[0] === 'create').length === 0, 'on_event creates no nodes (surgical, retained)');

instance.exports.on_event(3n, BigInt(EVENT.press));
ok(h.opLog.filter((o) => o[0] === 'set_attr' && o[1] === 2).pop()[3] === 2, 'second press -> count=2');

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
