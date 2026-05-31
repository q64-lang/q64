// Scene — the generic, VALIDATED retained-tree op applier.
//
// The single home for the five qview ops (create/set_attr/remove/on/present),
// shared by every host backend (WebGPU app.js, the soft renderer) and open to
// any producer (a q64 wasm today; an agent / socket feed tomorrow — same ops).
//
// SECURITY / ROBUSTNESS (spec/qview-protocol.md §"Host obligations"): every op
// is schema-validated before it touches the tree — known kind/attr/event tags,
// valid node refs, in-range values, depth/size caps. A malformed op (from a
// buggy producer OR an untrusted agent) is dropped with a diagnostic, never
// crashes the host. Rejecting is the safe default.
//
// The trust model this rests on (why it's safe by construction):
//  - The producer runs in the wasm sandbox: it can only call these imports,
//    nothing else (no DOM/net/storage).
//  - The ABI is integer-only — no pointers/strings cross the boundary, so there
//    is no memory-unsafety or text-injection vector. Text is host-owned (the
//    catalog), so a producer cannot inject renderable strings (no XSS path).
//  - This applier adds the remaining guard: it stops a producer from corrupting
//    the host's own tree with out-of-range / dangling / oversized ops.
import { KIND, ATTR, EVENT, KIND_NAME, ATTR_NAME } from './protocol.js';

const KINDS = new Set(Object.values(KIND));
const ATTRS = new Set(Object.values(ATTR));
const EVENTS = new Set(Object.values(EVENT));

// Caps — bound a producer's resource use (and an agent's blast radius).
const MAX_NODES = 10000;       // total live nodes
const MAX_DEPTH = 64;          // tree depth (cheap stack-overflow guard)
const MAX_CHILDREN = 4096;     // children of one node
const ID_MAX = 0x7fffffff;     // node ids fit a positive i32-ish range

export class Scene {
  // onReject(msg): optional diagnostic sink (default: console.warn). Kept off the
  // hot path — only called when an op is dropped.
  constructor({ onReject } = {}) {
    this.nodes = new Map();
    this.ROOT = 0;
    this.nodes.set(this.ROOT, this._mk(this.ROOT, -1, -1));
    this._onReject = onReject ?? ((m) => console.warn('[qview] reject:', m));
    this.muts = [];            // per-frame mutation log (diagnostics)
  }

  _mk(id, kind, parent) { return { id, kind, parent, attrs: new Map(), children: [], handlers: new Map() }; }
  _reject(m) { this._onReject(m); return false; }

  _depthOf(id) {
    let d = 0, n = this.nodes.get(id);
    while (n && n.parent >= 0) { d++; if (d > MAX_DEPTH + 1) break; n = this.nodes.get(n.parent); }
    return d;
  }

  // --- the validated ops. Each returns true if applied, false if rejected. ---
  create(id, kind, parent) {
    id = Number(id); kind = Number(kind); parent = Number(parent);
    if (!Number.isInteger(id) || id <= 0 || id > ID_MAX) return this._reject(`create: bad id ${id}`);
    if (!KINDS.has(kind)) return this._reject(`create #${id}: unknown kind ${kind}`);
    if (!this.nodes.has(parent)) return this._reject(`create #${id}: unknown parent ${parent}`);
    if (this.nodes.has(id)) {
      const n = this.nodes.get(id);
      if (n.kind !== kind) return this._reject(`create #${id}: kind conflict (${n.kind} != ${kind})`);
      return true;                                   // idempotent re-create
    }
    if (this.nodes.size >= MAX_NODES) return this._reject(`create #${id}: node cap (${MAX_NODES})`);
    const p = this.nodes.get(parent);
    if (p.children.length >= MAX_CHILDREN) return this._reject(`create #${id}: child cap on ${parent}`);
    if (this._depthOf(parent) >= MAX_DEPTH) return this._reject(`create #${id}: depth cap`);
    const node = this._mk(id, kind, p.id);
    this.nodes.set(id, node); p.children.push(id);
    this.muts.push(`create #${id} ${KIND_NAME[kind] ?? kind}`);
    return true;
  }

  set_attr(id, attr, value) {
    id = Number(id); attr = Number(attr);
    const n = this.nodes.get(id);
    if (!n) return this._reject(`set_attr: unknown node ${id}`);
    if (!ATTRS.has(attr)) return this._reject(`set_attr #${id}: unknown attr ${attr}`);
    // value stays raw (BigInt|number) — readers Number()/unpack it; we only
    // require it be a finite integer-ish value, not NaN/Infinity.
    const num = Number(value);
    if (!Number.isFinite(num)) return this._reject(`set_attr #${id} ${ATTR_NAME[attr]}: non-finite value`);
    n.attrs.set(attr, value);
    this.muts.push(`set_attr #${id} ${ATTR_NAME[attr] ?? attr}`);
    return true;
  }

  remove(id) {
    id = Number(id);
    if (id === this.ROOT) return this._reject('remove: cannot remove root');
    if (!this.nodes.has(id)) return true;            // removing unknown is a no-op
    this._removeSubtree(id);
    this.muts.push(`remove #${id}`);
    return true;
  }
  _removeSubtree(id) {
    const n = this.nodes.get(id); if (!n) return;
    for (const c of [...n.children]) this._removeSubtree(c);
    const p = this.nodes.get(n.parent); if (p) p.children = p.children.filter((c) => c !== id);
    this.nodes.delete(id);
    if (this.onNodeRemoved) this.onNodeRemoved(id);  // backend hook (glyph cache evict)
  }

  on(id, event, handler) {
    id = Number(id); event = Number(event); handler = Number(handler);
    const n = this.nodes.get(id);
    if (!n) return this._reject(`on: unknown node ${id}`);
    if (!EVENTS.has(event)) return this._reject(`on #${id}: unknown event ${event}`);
    if (!Number.isInteger(handler) || handler < 0) return this._reject(`on #${id}: bad handler ${handler}`);
    if (handler === 0) n.handlers.delete(event);
    else n.handlers.set(event, handler);
    return true;
  }

  // Build the import face for a producer (the wasm `qview` module). `present`
  // (the frame commit) is supplied by the backend, which renders + drains muts.
  face(present) {
    return {
      create: (id, k, p) => { this.create(id, k, p); },
      set_attr: (id, a, v) => { this.set_attr(id, a, v); },
      remove: (id) => { this.remove(id); },
      on: (id, e, h) => { this.on(id, e, h); },
      present: () => present(),
    };
  }

  drainMuts() { const m = this.muts; this.muts = []; return m; }
  get(id) { return this.nodes.get(Number(id)); }
}
