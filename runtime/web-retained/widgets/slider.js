// slider (kind 10): a draggable track + filled portion + knob. Supports BOTH
// orientations — VERTICAL when h > w (a tall slider), else horizontal. The wasm
// owns ATTR.value; the host turns a touch/drag position into a value PAYLOAD via
// value() and passes it to the handler. Press jumps to the touch; drag tracks.
// Vertical fills bottom-up (value increases upward — the usual convention).
import { KIND, ATTR } from '../protocol.js';
import { register } from '../registry.js';

const TRACK = 6;     // track thickness
const KNOB = 20;     // knob diameter

const geom = (node, r) => ({
  x: r.attr(node, ATTR.x, 0), y: r.attr(node, ATTR.y, 0),
  w: r.attr(node, ATTR.w, 200), h: r.attr(node, ATTR.h, 28),
});
const isVert = (g) => g.h > g.w;
const frac = (node, r) => {
  const min = r.attr(node, ATTR.min, 0), max = r.attr(node, ATTR.max, 100);
  const span = max - min; if (span === 0) return 0;
  return Math.max(0, Math.min(1, (r.attr(node, ATTR.value, 0) - min) / span));
};

register(KIND.slider, {
  draw(node, r) {
    const g = geom(node, r);
    const f = frac(node, r);
    if (isVert(g)) {
      const cx = g.x + g.w / 2;
      const trackX = cx - TRACK / 2;
      r.drawPrim(r.pass, trackX, g.y, TRACK, g.h, r.theme.track, { radius: TRACK / 2 });
      // knob travels y+h-KNOB (bottom, f=0) up to y (top, f=1)
      const knobY = g.y + (1 - f) * (g.h - KNOB);
      const fillTop = knobY + KNOB / 2;
      r.drawPrim(r.pass, trackX, fillTop, TRACK, g.y + g.h - fillTop, r.theme.accent, { radius: TRACK / 2 });
      r.drawPrim(r.pass, cx - KNOB / 2, knobY, KNOB, KNOB, r.theme.fg, { radius: KNOB / 2, border: 2, borderColor: r.theme.border });
    } else {
      const cy = g.y + g.h / 2;
      const trackY = cy - TRACK / 2;
      r.drawPrim(r.pass, g.x, trackY, g.w, TRACK, r.theme.track, { radius: TRACK / 2 });
      const knobX = g.x + f * (g.w - KNOB);
      const fillW = knobX + KNOB / 2 - g.x;
      if (fillW > 0) r.drawPrim(r.pass, g.x, trackY, fillW, TRACK, r.theme.accent, { radius: TRACK / 2 });
      r.drawPrim(r.pass, knobX, cy - KNOB / 2, KNOB, KNOB, r.theme.fg, { radius: KNOB / 2, border: 2, borderColor: r.theme.border });
    }
  },
  hit(node, px, py, r) {
    const g = geom(node, r);
    return px >= g.x && px <= g.x + g.w && py >= g.y && py <= g.y + g.h;
  },
  // Map a touch position to a value. Horizontal uses x; vertical uses y inverted
  // (top = max). Travel excludes the knob so both ends are reachable.
  value(node, px, py, r) {
    const g = geom(node, r);
    const min = r.attr(node, ATTR.min, 0), max = r.attr(node, ATTR.max, 100);
    let f;
    if (isVert(g)) {
      const lo = g.y + KNOB / 2, hi = g.y + g.h - KNOB / 2;
      f = hi > lo ? 1 - (py - lo) / (hi - lo) : 0;   // inverted: top = 1
    } else {
      const lo = g.x + KNOB / 2, hi = g.x + g.w - KNOB / 2;
      f = hi > lo ? (px - lo) / (hi - lo) : 0;
    }
    f = Math.max(0, Math.min(1, f));
    return Math.round(min + f * (max - min));
  },
  measure(node, r) {
    const g = geom(node, r);
    return isVert(g) ? { w: 28, h: 160 } : { w: 200, h: 28 };
  },
});
