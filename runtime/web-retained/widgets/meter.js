// meter (kind 15): a vertical level / peak meter. Stereo when w is wide enough
// for two channels (left = ATTR.value, right = ATTR.value2); else a single bar.
// Each channel fills BOTTOM-UP to its level on the min..max scale, with a
// classic green -> yellow -> red gradient (segments) and a peak-hold marker
// (ATTR.peak / ATTR.peak2). Non-interactive — it's an output display.
import { KIND, ATTR } from '../protocol.js';
import { register } from '../registry.js';

const SEGMENTS = 16;     // discrete LED-style segments per channel
const SEG_GAP = 2;       // px between segments
const CH_GAP = 4;        // px between the two channels

const rgb = (r, g, b) => [r / 255, g / 255, b / 255, 1];
const GREEN = rgb(48, 209, 88), YELLOW = rgb(255, 214, 10), RED = rgb(255, 69, 58);
// Segment color by its fraction up the bar (top segments are hotter).
function segColor(frac) { return frac > 0.85 ? RED : frac > 0.6 ? YELLOW : GREEN; }

function drawChannel(r, x, y, w, h, level, peak, min, max) {
  const span = max - min || 1;
  const lf = Math.max(0, Math.min(1, (level - min) / span));
  const pf = Math.max(0, Math.min(1, (peak - min) / span));
  const segH = (h - SEG_GAP * (SEGMENTS - 1)) / SEGMENTS;
  for (let i = 0; i < SEGMENTS; i++) {
    const frac = (i + 0.5) / SEGMENTS;                 // this segment's position 0..1
    const segY = y + h - (i + 1) * segH - i * SEG_GAP; // bottom-up
    const lit = frac <= lf;
    // unlit segments are a dim track; lit ones take the gradient color.
    const col = lit ? segColor(frac) : r.theme.track;
    r.drawPrim(r.pass, x, segY, w, segH, col, { radius: 1 });
  }
  // Peak-hold: a bright line at the peak fraction.
  if (pf > 0) {
    const py = y + h - pf * h - 1;
    r.drawPrim(r.pass, x, py, w, 2, segColor(pf), { radius: 1 });
  }
}

register(KIND.meter, {
  draw(node, r) {
    const x = r.attr(node, ATTR.x, 0), y = r.attr(node, ATTR.y, 0);
    const w = r.attr(node, ATTR.w, 28), h = r.attr(node, ATTR.h, 150);
    const min = r.attr(node, ATTR.min, 0), max = r.attr(node, ATTR.max, 100);
    const stereo = node.attrs.has(ATTR.value2);
    if (stereo) {
      const cw = (w - CH_GAP) / 2;
      drawChannel(r, x, y, cw, h, r.attr(node, ATTR.value, 0), r.attr(node, ATTR.peak, 0), min, max);
      drawChannel(r, x + cw + CH_GAP, y, cw, h, r.attr(node, ATTR.value2, 0), r.attr(node, ATTR.peak2, 0), min, max);
    } else {
      drawChannel(r, x, y, w, h, r.attr(node, ATTR.value, 0), r.attr(node, ATTR.peak, 0), min, max);
    }
  },
  measure(node, r) {
    const stereo = node.attrs.has(ATTR.value2);
    return { w: stereo ? 28 : 14, h: 150 };
  },
});
