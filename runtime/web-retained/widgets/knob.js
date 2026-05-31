// knob (kind 16): a rotary control (pan, volume, …). value on the min..max scale.
// Drag VERTICALLY to change (up = increase). Circular body + value arc + an
// indicator dot at the value angle, over a 270° sweep (~7 o'clock to ~5 o'clock).
//
// BIPOLAR mode (ATTR.checked = 1): a center-detent control like PAN. min..max is
// symmetric (e.g. -100..+100); the arc grows FROM the center (12 o'clock) toward
// the value side — left for negative, right for positive — instead of filling
// from one end. Center (0) lights nothing but the center tick.
import { KIND, ATTR } from '../protocol.js';
import { register } from '../registry.js';

const A0 = Math.PI * 0.75;          // start angle (135°, bottom-left)
const SWEEP = Math.PI * 1.5;        // 270° total
const DRAG_RANGE = 160;             // px of vertical drag = full travel
const N = 24;                       // arc dots

const geom = (node, r) => ({
  x: r.attr(node, ATTR.x, 0), y: r.attr(node, ATTR.y, 0),
  w: r.attr(node, ATTR.w, 56), h: r.attr(node, ATTR.h, 56),
});
// fraction 0..1 of value across min..max.
function frac(node, r) {
  const min = r.attr(node, ATTR.min, 0), max = r.attr(node, ATTR.max, 100);
  const span = max - min || 1;
  return Math.max(0, Math.min(1, (r.attr(node, ATTR.value, 0) - min) / span));
}
const isBipolar = (node, r) => r.attr(node, ATTR.checked, 0) === 1;

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
    const f = frac(node, r);            // 0..1
    const arcR = rad - 4;
    const bip = isBipolar(node, r);
    r.drawPrim(r.pass, cx - rad, cy - rad, size, size, r.theme.surface, { radius: rad, border: 2, borderColor: r.theme.border });

    for (let i = 0; i <= N; i++) {
      const t = i / N;                  // 0..1 along the sweep
      const a = A0 + t * SWEEP;
      let lit;
      if (bip) {
        // Light dots BETWEEN the center (t=0.5) and the value fraction f.
        lit = f >= 0.5 ? (t >= 0.5 && t <= f) : (t <= 0.5 && t >= f);
      } else {
        lit = t <= f;                   // unipolar: fill from the start
      }
      dot(r, cx, cy, arcR, a, 3, lit ? r.theme.accent : r.theme.track);
    }
    // Center tick (bipolar): a brighter marker at 12 o'clock so 0 is obvious.
    if (bip) dot(r, cx, cy, arcR, A0 + 0.5 * SWEEP, 4, r.theme.muted);
    // Indicator dot at the value angle.
    dot(r, cx, cy, rad - 10, A0 + f * SWEEP, 6, r.theme.fg);
  },
  hit(node, px, py, r) {
    const g = geom(node, r);
    return px >= g.x && px <= g.x + g.w && py >= g.y && py <= g.y + g.h;
  },
  value(node, px, py, r) {
    const min = r.attr(node, ATTR.min, 0), max = r.attr(node, ATTR.max, 100);
    const g = geom(node, r);
    const cy = g.y + g.h / 2;
    const f = Math.max(0, Math.min(1, 0.5 - (py - cy) / DRAG_RANGE));
    return Math.round(min + f * (max - min));
  },
  measure(node, r) { return { w: 56, h: 56 }; },
});
