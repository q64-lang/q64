// QView Stage-1 RETAINED host (WebGPU). spec/qview-protocol.md.
//
// Unlike the immediate-mode POC (runtime/web/app.js), this host keeps a RETAINED
// node tree (node_id -> record). The wasm builds it once via create/set_attr/on,
// then mutates it surgically from the on_event dispatcher. present() re-encodes
// the current tree. Node identity (and thus future focus/caret/scroll) is the
// node_id, preserved across frames — never a blind full re-emit.
import { KIND, ATTR, EVENT, EVENT_NAME, SURFACE, unpackColor, PROTOCOL_VERSION } from './protocol.js';
import { initGPU, drawPrim, sdfTexture, beginFrame, endFrame, DPR } from './gpu.js';
import { widgetFor } from './widgets.js';
import { resolvePlatform } from './platform.js';
import { themeFor } from './theme.js';

// One self-drawn renderer, three looks: iOS-ish on iOS, Material-ish on Android,
// a neutral house look on desktop. The platform is resolved once (sniff +
// ?platform= override); the per-platform theme tokens flow to every widget via
// r.platform / r.theme. Shaders and the protocol are unchanged — only tokens and
// (for structurally-different controls) per-platform draw variants differ.
const PLATFORM = resolvePlatform();
const THEME = themeFor(PLATFORM);

const log = (m) => { const el = document.getElementById('log'); if (el) el.textContent = m; console.log('[qview]', m); };

// Host-owned glyph catalog (Stage-1 text-by-id; no strings cross wasm). A label
// whose text_id < CATALOG.length shows that string; otherwise the id is rendered
// as an integer (the POC's `number` path — live counters etc.).
const CATALOG = [
  'Widget gallery',  // 0
  'Label',           // 1
  'Button',          // 2
  'Checkbox',        // 3
  'Switch',          // 4
  'Radio A',         // 5
  'Radio B',         // 6
  'Slider',          // 7
  'Progress',        // 8
  'Option one',      // 9
  'Box',             // 10
  'Tap +1',          // 11
];

// ---- the retained tree -------------------------------------------------------
// id -> { id, kind, parent, attrs:Map<attr,i64>, children:[id], handlers:Map<event,handlerId> }
const nodes = new Map();
const ROOT = 0;
nodes.set(ROOT, { id: ROOT, kind: -1, parent: -1, attrs: new Map(), children: [], handlers: new Map() });

let glyphCache = new Map();  // nodeId -> {tex,view,w,h}; rebuilt only when text changes
let glyphKey = new Map();    // nodeId -> last text string used, to skip rebuilds
let pressedId = null;
let pendingMuts = [];        // mutation log for the current frame (diagnostics)
let instance;

function textStringFor(node) {
  const id = node.attrs.get(ATTR.text_id);
  if (id === undefined) return null;
  const n = Number(id);
  return (n >= 0 && n < CATALOG.length) ? CATALOG[n] : String(n);
}
function glyphFor(node) {
  const str = textStringFor(node);
  if (str === null) return null;
  if (glyphKey.get(node.id) !== str) {           // surgical: only a changed text re-rasterizes
    glyphCache.set(node.id, sdfTexture(str));
    glyphKey.set(node.id, str);
  }
  return glyphCache.get(node.id);
}

// ---- the five ops (the wasm import face) ------------------------------------
function ops() {
  return {
    env: { out: () => {} },
    qview: {
      create: (id, kind, parent) => {
        id = Number(id); kind = Number(kind); parent = Number(parent);
        if (nodes.has(id)) { const n = nodes.get(id); if (n.kind !== kind) log(`proto error: create #${id} kind conflict`); return; }
        const p = nodes.get(parent) ?? nodes.get(ROOT);
        const node = { id, kind, parent: p.id, attrs: new Map(), children: [], handlers: new Map() };
        nodes.set(id, node); p.children.push(id);
        pendingMuts.push(`create #${id} ${kindName(kind)}`);
      },
      set_attr: (id, attr, value) => {
        const n = nodes.get(Number(id)); if (!n) { log(`proto error: set_attr on unknown #${id}`); return; }
        n.attrs.set(Number(attr), value);            // keep raw i64 (BigInt); readers Number()/unpack
        pendingMuts.push(`set_attr #${Number(id)} ${attrName(attr)}`);
        glyphKey.delete(Number(id));                 // text may have changed; force re-eval on draw
      },
      remove: (id) => {
        id = Number(id); const n = nodes.get(id); if (!n) return;
        removeSubtree(id);
        pendingMuts.push(`remove #${id}`);
      },
      on: (id, event, handler) => {
        const n = nodes.get(Number(id)); if (!n) return;
        if (Number(handler) === 0) n.handlers.delete(Number(event));
        else n.handlers.set(Number(event), Number(handler));
      },
      present: () => { render(); if (pendingMuts.length) { log('mutate: ' + pendingMuts.join(', ')); pendingMuts = []; } },
    },
  };
}

function removeSubtree(id) {
  const n = nodes.get(id); if (!n) return;
  for (const c of [...n.children]) removeSubtree(c);
  const p = nodes.get(n.parent); if (p) p.children = p.children.filter((c) => c !== id);
  nodes.delete(id); glyphCache.delete(id); glyphKey.delete(id);
}

const kindName = (k) => Object.keys(KIND).find((n) => KIND[n] === k) ?? `kind${k}`;
const attrName = (a) => Object.keys(ATTR).find((n) => ATTR[n] === a) ?? `attr${a}`;

// ATTR.surface role tag -> theme token key (the translucent material fills).
const SURFACE_KEY = { [SURFACE.none]: 'none', [SURFACE.surface]: 'surface', [SURFACE.material]: 'material', [SURFACE.materialThin]: 'materialThin', [SURFACE.scrim]: 'scrim' };

// ---- render: walk the retained tree, dispatch each node to its widget --------
const renderCtx = {
  pass: null, drawPrim, sdfText: sdfTexture, theme: THEME, platform: PLATFORM,
  attr: (node, a, dflt) => { const v = node.attrs.get(a); return v === undefined ? dflt : Number(v); },
  color: (node, a, dflt) => { const v = node.attrs.get(a); return v === undefined ? dflt : unpackColor(v); },
  // Resolve a node's fill, honoring a semantic ATTR.surface role (theme-resolved
  // translucent material) over a literal ATTR.fill over the given default.
  surfaceFill: (node, dflt) => {
    const role = node.attrs.get(ATTR.surface);
    if (role !== undefined) {
      const key = SURFACE_KEY[Number(role)];
      if (key && key !== 'none') return THEME[key] ?? dflt;
      if (key === 'none') return null;
    }
    const lit = node.attrs.get(ATTR.fill);
    return lit === undefined ? dflt : unpackColor(lit);
  },
  textFor: (node) => glyphFor(node),
  isPressed: (id) => id === pressedId,
};

function render() {
  const frame = beginFrame(THEME.bg);
  renderCtx.pass = frame.pass;
  walk(ROOT);
  endFrame(frame);
}
function walk(id) {
  const n = nodes.get(id); if (!n) return;
  if (id !== ROOT) {
    const w = widgetFor(n.kind);
    if (w && w.draw) w.draw(n, renderCtx);
    else if (id !== ROOT) { /* unknown/undrawn kind: skip (e.g. pure layout in Stage 1) */ }
  }
  for (const c of n.children) walk(c);
}

// ---- input: hit-test the tree, fire the wired handler via on_event -----------
function hitTest(px, py) {
  // Topmost-first: later children draw over earlier; walk in reverse.
  let found = null;
  const visit = (id) => {
    const n = nodes.get(id); if (!n) return;
    for (let i = n.children.length - 1; i >= 0; i--) visit(n.children[i]);
    if (found) return;
    if (id !== ROOT) {
      const w = widgetFor(n.kind);
      if (w && w.hit && w.hit(n, px, py, renderCtx)) found = n;
    }
  };
  visit(ROOT);
  return found;
}

function dispatch(node, event) {
  const handler = node.handlers.get(event);
  if (handler === undefined) return;
  // Stage-1 dispatch (spec/qview-protocol.md §Events). The wasm handler reads
  // state, mutates the exact node(s), and calls present(). Two shapes, in order:
  //   1. per-handler export `on_<id>` (the handler id from qview.on) — branchless,
  //      one export per wired control; what the compiler emits cleanly today.
  //   2. single dispatcher `on_event(node, event)` — fallback when no on_<id>.
  // Both take (node, event) i64 args so a handler can still tell what fired.
  const perHandler = instance.exports[`on_${handler}`];
  const fn = typeof perHandler === 'function' ? perHandler : instance.exports.on_event;
  if (typeof fn === 'function') fn(BigInt(node.id), BigInt(event));
  else log(`wasm exports no on_${handler} or on_event`);
}

async function main() {
  const canvas = document.getElementById('gpu');
  const resize = () => { canvas.width = Math.round(canvas.clientWidth * DPR); canvas.height = Math.round(canvas.clientHeight * DPR); };
  try { await initGPU(canvas); }
  catch (e) { log('WebGPU unavailable: ' + e.message + ' — open in a WebGPU-capable browser (iPad Safari 18+).'); return; }
  resize();

  const resp = await fetch('./screen.wasm');
  const bytes = await resp.arrayBuffer();
  const { instance: inst } = await WebAssembly.instantiate(bytes, ops());
  instance = inst;
  log(`retained host v${PROTOCOL_VERSION} · wasm32 (${bytes.byteLength} B) · WebGPU`);

  instance.exports._start();   // builds the retained tree + first present()

  canvas.addEventListener('pointerdown', (ev) => {
    const r = canvas.getBoundingClientRect();
    const hit = hitTest(ev.clientX - r.left, ev.clientY - r.top);
    if (!hit) return;
    pressedId = hit.id; render();                       // immediate pressed-state flash
    dispatch(hit, EVENT.press);                         // wasm mutates + presents
    setTimeout(() => { pressedId = null; render(); }, 120);
  });
  window.addEventListener('resize', () => { resize(); render(); });
}
main();
