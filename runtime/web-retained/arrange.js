// Layout engine — SwiftUI-style HStack / VStack arrangement.
//
// Stage-1 was positional (every node carried an absolute x/y). This adds an
// optional ARRANGE pass so `row` (HStack) and `column` (VStack) OWN their
// children's positions: lay them along the main axis with ATTR.gap, align them
// on the cross axis (ATTR.align), inside the parent's ATTR.pad. A child still
// MAY carry explicit x/y (mixed mode), but inside a stack the stack wins.
//
// Two phases over the retained tree, run before draw:
//   measure(node): intrinsic size {w,h} — explicit ATTR.w/h if set, else the
//     widget's natural size (widget.measure), else children's bounds. Bottom-up.
//   arrange(node, x, y): write each node's resolved rect into a layout map the
//     render/hit code reads. Top-down. A stack positions its children; a plain
//     container places children at their own x/y.
//
// The resolved geometry lives in a side map (node.id -> {x,y,w,h}) — the wasm's
// attrs are NOT mutated, so the retained/surgical model is untouched and a
// re-layout is just recomputing the map (cheap; dirty-tracking is a follow-up).
import { KIND, ATTR, ALIGN } from './protocol.js';
import { widgetFor } from './widgets.js';

const STACK = new Set([KIND.row, KIND.column]);
const isRow = (kind) => kind === KIND.row;

// Read a numeric attr (host stores raw BigInt|number).
const attr = (node, a, d) => { const v = node.attrs.get(a); return v === undefined ? d : Number(v); };
const has = (node, a) => node.attrs.has(a);

// Intrinsic size of a node. r is the render context (for widget.measure, which
// may need text metrics). Returns {w,h}.
export function measure(scene, node, r) {
  const w = widgetFor(node.kind);
  // Explicit size wins.
  let mw = has(node, ATTR.w) ? attr(node, ATTR.w, 0) : null;
  let mh = has(node, ATTR.h) ? attr(node, ATTR.h, 0) : null;

  if (STACK.has(node.kind)) {
    // A stack's intrinsic size = lay children out and bound them.
    const pad = attr(node, ATTR.pad, 0);
    const gap = attr(node, ATTR.gap, 0);
    const kids = node.children.map((id) => scene.get(id)).filter(Boolean);
    let main = 0, cross = 0;
    for (const k of kids) {
      const ks = measure(scene, k, r);
      if (isRow(node.kind)) { main += ks.w; cross = Math.max(cross, ks.h); }
      else { main += ks.h; cross = Math.max(cross, ks.w); }
    }
    if (kids.length > 1) main += gap * (kids.length - 1);
    const natW = isRow(node.kind) ? main : cross;
    const natH = isRow(node.kind) ? cross : main;
    return { w: mw ?? (natW + pad * 2), h: mh ?? (natH + pad * 2) };
  }

  // A widget may declare its natural size.
  if ((mw === null || mh === null) && w && w.measure) {
    const nat = w.measure(node, r) || {};
    if (mw === null && nat.w != null) mw = nat.w;
    if (mh === null && nat.h != null) mh = nat.h;
  }
  return { w: mw ?? 0, h: mh ?? 0 };
}

// Arrange: write resolved rects into `out` (Map id->{x,y,w,h}). For a stack,
// position children along the main axis; otherwise recurse placing children at
// their own (possibly absolute) coords. self {x,y,w,h} is this node's rect.
export function arrange(scene, node, self, r, out) {
  out.set(node.id, self);

  if (STACK.has(node.kind)) {
    const pad = attr(node, ATTR.pad, 0);
    const gap = attr(node, ATTR.gap, 0);
    const align = attr(node, ATTR.align, ALIGN.start);
    const kids = node.children.map((id) => scene.get(id)).filter(Boolean);
    let cursor = isRow(node.kind) ? self.x + pad : self.y + pad;
    const crossStart = isRow(node.kind) ? self.y + pad : self.x + pad;
    const crossSize = (isRow(node.kind) ? self.h : self.w) - pad * 2;
    for (const k of kids) {
      const ks = measure(scene, k, r);
      // Cross-axis placement per align.
      const kCross = isRow(node.kind) ? ks.h : ks.w;
      let crossPos = crossStart;
      let crossLen = isRow(node.kind) ? ks.h : ks.w;
      if (align === ALIGN.center) crossPos = crossStart + (crossSize - kCross) / 2;
      else if (align === ALIGN.end) crossPos = crossStart + (crossSize - kCross);
      else if (align === ALIGN.stretch) crossLen = crossSize;
      const kx = isRow(node.kind) ? cursor : crossPos;
      const ky = isRow(node.kind) ? crossPos : cursor;
      const kw = isRow(node.kind) ? ks.w : crossLen;
      const kh = isRow(node.kind) ? crossLen : ks.h;
      arrange(scene, k, { x: kx, y: ky, w: kw, h: kh }, r, out);
      cursor += (isRow(node.kind) ? ks.w : ks.h) + gap;
    }
    return;
  }

  // Plain container (box/group): a child's x/y is an OFFSET relative to the
  // parent's origin (so a group's content sits inside it, not at page 0,0). A
  // child without x/y sits at the parent origin. (ROOT is the exception — its
  // children are absolute page coords; see computeLayout.)
  for (const id of node.children) {
    const k = scene.get(id); if (!k) continue;
    const ks = measure(scene, k, r);
    const kx = self.x + (has(k, ATTR.x) ? attr(k, ATTR.x, 0) : 0);
    const ky = self.y + (has(k, ATTR.y) ? attr(k, ATTR.y, 0) : 0);
    arrange(scene, k, { x: kx, y: ky, w: ks.w, h: ks.h }, r, out);
  }
}

// Compute the full layout map for the tree under ROOT. Root's children are
// placed at their own x/y (the screen is an absolute canvas); stacks within
// take over their subtrees. Returns Map<id, {x,y,w,h}>.
export function computeLayout(scene, r) {
  const out = new Map();
  const root = scene.get(scene.ROOT);
  out.set(scene.ROOT, { x: 0, y: 0, w: 0, h: 0 });
  for (const id of root.children) {
    const k = scene.get(id); if (!k) continue;
    const ks = measure(scene, k, r);
    const kx = has(k, ATTR.x) ? attr(k, ATTR.x, 0) : 0;
    const ky = has(k, ATTR.y) ? attr(k, ATTR.y, 0) : 0;
    arrange(scene, k, { x: kx, y: ky, w: ks.w, h: ks.h }, r, out);
  }
  return out;
}
