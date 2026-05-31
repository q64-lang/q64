// knob (kind 16): a rotary control (pan, volume, …). value on the min..max scale.
// Drag VERTICALLY to change (up = increase) — the standard knob interaction;
// far more precise than trying to drag in a circle. Draws a circular body, a
// value arc, and an indicator line pointing to the value's angle (~7-o'clock to
// ~5-o'clock sweep, like a hardware pot).
import { KIND, ATTR } from '../protocol.js';
import { register } from '../registry.js';

// Sweep: 270° total, from 135° (bottom-left) clockwise to 405°(=45°, bottom-right).
const A0 = Math.PI * 0.75;          // start angle (135°)
const SWEEP = Math.PI * 1.5;        // 270°
const DRAG_RANGE = 160;             // px of vertical drag = full min..max travel

const geom = (node, r) => ({
  x: r.attr(node, ATTR.x, 0), y: r.attr(node, ATTR.y, 0),
  w: r.attr(node, ATTR.w, 56), h: r.attr(node, ATTR.h, 56),
});
const frac = (node, r) => {
  const min = r.attr(node, ATTR.min, 0), max = r.attr(node, ATTR.max, 100);
  const span = max - min || 1;
  return Math.max(0, Math.min(1, (r.attr(node, ATTR.value, 0) - min) / span));
};

// A small filled dot at angle a on radius rad around (cx,cy) — used to draw the
// arc + indicator as a few dots (no path primitive in Stage 1; SDF dots suffice).
function dot(r, cx, cy, rad, a, d, col) {
  const px = cx + Math.cos(a) * rad, py = cy + Math.sin(a) * rad;
  r.drawPrim(r.pass, px - d / 2, py - d / 2, d, d, col, { radius: d / 2 });
}

register(KIND.knob, {
  draw(node, r) {
    const g = geom(node, r);
    const size = Math.min(g.w, g.h);
    const cx = g.x + g.w / 2, cy = g.y + size / 2;
    const rad = size / 2;
    const f = frac(node, r);
    // Body.
    r.drawPrim(r.pass, cx - rad, cy - rad, size, size, r.theme.surface, { radius: rad, border: 2, borderColor: r.theme.border });
    // Range arc (dim) + value arc (accent), as dots along the sweep.
    const arcR = rad - 4;
    const N = 24;
    for (let i = 0; i <= N; i++) {
      const t = i / N;
      const a = A0 + t * SWEEP;
      dot(r, cx, cy, arcR, a, 3, t <= f ? r.theme.accent : r.theme.track);
    }
    // Indicator line: a dot near the rim at the value angle.
    const a = A0 + f * SWEEP;
    dot(r, cx, cy, rad - 10, a, 6, r.theme.fg);
  },
  hit(node, px, py, r) {
    const g = geom(node, r);
    return px >= g.x && px <= g.x + g.w && py >= g.y && py <= g.y + g.h;
  },
  // Vertical drag -> value. Up increases. The drag delta from the press point is
  // scaled over DRAG_RANGE; we anchor to the press position so it feels stable.
  value(node, px, py, r) {
    const min = r.attr(node, ATTR.min, 0), max = r.attr(node, ATTR.max, 100);
    const g = geom(node, r);
    // Map py within the knob's vertical band to the value range (top=max).
    const cy = g.y + g.h / 2;
    const f = Math.max(0, Math.min(1, 0.5 - (py - cy) / DRAG_RANGE));
    return Math.round(min + f * (max - min));
  },
  measure(node, r) { return { w: 56, h: 56 }; },
});
