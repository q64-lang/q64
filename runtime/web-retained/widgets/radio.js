// radio (kind 9): one selectable circle of an exclusive group.
// ATTR.group drives exclusivity in the producer (the wasm) — radios sharing a
// group id are mutually exclusive. This widget only renders THIS node's
// selected state (ATTR.selected); it never mutates: the wasm sets ATTR.selected
// on press and re-presents.
import { KIND, ATTR } from '../protocol.js';
import { register } from '../registry.js';

const SIZE = 24;   // default outer circle diameter (CSS px)
const DOT = 10;    // inner filled dot diameter when selected

register(KIND.radio, {
  draw(node, r) {
    const x = r.attr(node, ATTR.x, 0), y = r.attr(node, ATTR.y, 0);
    const w = r.attr(node, ATTR.w, SIZE), h = r.attr(node, ATTR.h, SIZE);
    // Outer circle: rounded-rect with radius = size/2, transparent fill, border.
    r.drawPrim(r.pass, x, y, w, h, [0, 0, 0, 0], {
      radius: Math.min(w, h) / 2,
      border: 2,
      borderColor: r.theme.border,
    });
    // Inner dot when selected.
    if (r.attr(node, ATTR.selected, 0) === 1) {
      const dx = x + (w - DOT) / 2, dy = y + (h - DOT) / 2;
      r.drawPrim(r.pass, dx, dy, DOT, DOT, r.theme.accent, { radius: DOT / 2 });
    }
  },
  hit(node, px, py, r) {
    const x = r.attr(node, ATTR.x, 0), y = r.attr(node, ATTR.y, 0);
    const w = r.attr(node, ATTR.w, SIZE), h = r.attr(node, ATTR.h, SIZE);
    // Radial distance test against the circle (nicer than a bounding box).
    const cx = x + w / 2, cy = y + h / 2, rr = Math.min(w, h) / 2;
    const ddx = px - cx, ddy = py - cy;
    return ddx * ddx + ddy * ddy <= rr * rr;
  },
});
