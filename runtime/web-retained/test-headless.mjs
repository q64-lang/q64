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
  91: KIND.label, 100: KIND.column, 10: KIND.label, 20: KIND.button, 21: KIND.label,
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
ok(h.nodes.get(90)?.kind === KIND.box, 'material bar node 90 is a box');
ok(h.nodes.get(90)?.attrs.get(ATTR.surface) === 1, 'bar carries surface=surface (opaque, 1)');

// --- per-handler surgical mutations via the on_<id> exports ---
// Handlers take (node, event, payload) i64. payload is the host-computed value
// (the slider's value from the touch position); others ignore it.
const handlerFires = (id, expectSets, payload = 0) => {
  const fn = instance.exports[`on_${id}`];
  ok(typeof fn === 'function', `export on_${id} exists`);
  const before = h.opLog.length;
  fn(BigInt(id), BigInt(EVENT.press), BigInt(payload));
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
// Slider: the value payload becomes the value (NOT +10) — tap-position driven.
handlerFires(60, [60, 70], 25); // payload 25 -> value 25
ok(h.nodes.get(60).attrs.get(ATTR.value) === 25 && h.nodes.get(70).attrs.get(ATTR.value) === 25, 'slider+progress set to payload 25');
handlerFires(60, [60, 70], 80); // a second drag position -> 80 (not 35)
ok(h.nodes.get(60).attrs.get(ATTR.value) === 80, 'slider follows payload to 80 (absolute, not incremental)');
// Dropdown: payload is the chosen option's catalog id (12..15). Selecting
// 'Windows' (id 14) sets the field text_id=14 and selected index=14-12=2.
ok(h.nodes.get(80).attrs.get(ATTR.min) === 1012, 'dropdown options base = catalog id 1012');
ok(h.nodes.get(80).attrs.get(ATTR.max) === 4, 'dropdown has 4 options (iOS/Android/Windows/Linux)');
handlerFires(80, [80], 1014); // choose Windows
ok(h.nodes.get(80).attrs.get(ATTR.text_id) === 1014, 'dropdown field shows chosen option (Windows=1014)');
ok(h.nodes.get(80).attrs.get(ATTR.selected) === 2, 'dropdown selected index = 2');
// Grouped child: checkbox 8 is parented to group 6, wired, and toggles.
ok(h.nodes.get(8)?.kind === KIND.checkbox && h.nodes.get(190)?.parent === 6, 'checkbox 8 is in the group content VStack (190) under group 6');
ok(h.nodes.get(8)?.handlers.get(EVENT.press) === 8, 'grouped checkbox wired press -> handler 8');
handlerFires(8, [8]); // toggle the grouped checkbox
ok(h.nodes.get(8).attrs.get(ATTR.checked) === 0, 'grouped checkbox toggled off');

// Fader drives the stereo peak meter: on_322(value) sets the meter (332)
// value/value2/peak/peak2.
ok(h.nodes.get(332)?.kind === KIND.meter, 'node 332 is a meter');
const before322 = h.opLog.length;
instance.exports.on_322(322n, BigInt(EVENT.press), 70n);
const d322 = h.opLog.slice(before322).filter((o) => o[0] === 'set_attr' && o[1] === 332).map((o) => o[2]);
ok(d322.includes(ATTR.value) && d322.includes(ATTR.value2) && d322.includes(ATTR.peak), 'fader updates meter value/value2/peak');
ok(h.nodes.get(332).attrs.get(ATTR.value) === 70, 'meter left level = fader value (70)');

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
