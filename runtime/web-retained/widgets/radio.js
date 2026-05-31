// radio (kind 9): one selectable circle of an exclusive group.
// ATTR.group drives exclusivity in the producer (the wasm); this widget renders
// THIS node's ATTR.selected and never mutates (the wasm flips it on press).
//
// Touch: the node's w/h is the HIT ROW (circle + its label), not the circle —
// a 24px circle alone is far too small to tap, and the label sits outside it.
// The circle is drawn at a fixed size, anchored left and vertically centered in
// the row; the whole row (min 44px tall, the iOS/Material touch target) is hit.
import { KIND, ATTR } from '../protocol.js';
import { register } from '../registry.js';

const CIRCLE = 22;        // visual outer circle diameter (CSS px)
const DOT = 10;           // inner filled dot when selected
const MIN_TOUCH = 44;     // minimum touch target (HIG / Material)
const DEFAULT_W = 120;    // default hit-row width (covers a short label)

function box(node, r) {
  const x = r.attr(node, ATTR.x, 0), y = r.attr(node, ATTR.y, 0);
  const w = Math.max(r.attr(node, ATTR.w, DEFAULT_W), CIRCLE);
  const h = Math.max(r.attr(node, ATTR.h, MIN_TOUCH), MIN_TOUCH);
  return { x, y, w, h };
}

register(KIND.radio, {
  draw(node, r) {
    const { x, y, h } = box(node, r);
    const cy = y + (h - CIRCLE) / 2;             // circle vertically centered in the row
    // Outer circle: transparent fill, border (accent when selected for feedback).
    const selected = r.attr(node, ATTR.selected, 0) === 1;
    r.drawPrim(r.pass, x, cy, CIRCLE, CIRCLE, [0, 0, 0, 0], {
      radius: CIRCLE / 2,
      border: 2,
      borderColor: selected ? r.theme.accent : r.theme.border,
    });
    if (selected) {
      const dx = x + (CIRCLE - DOT) / 2, dy = cy + (CIRCLE - DOT) / 2;
      r.drawPrim(r.pass, dx, dy, DOT, DOT, r.theme.accent, { radius: DOT / 2 });
    }
  },
  hit(node, px, py, r) {
    // The whole row is touchable (circle + label area), not just the circle.
    const { x, y, w, h } = box(node, r);
    return px >= x && px <= x + w && py >= y && py <= y + h;
  },
  measure(node, r) { return { w: 120, h: 44 }; },
});
