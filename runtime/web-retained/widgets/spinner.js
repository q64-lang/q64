// spinner (kind 20): a round animated wait cursor — a ring of dots with a
// trailing fade that rotates over time. No rotation transform needed (drawPrim
// is axis-aligned): the "rotation" is the bright spot moving around the ring via
// per-dot opacity. The host runs a requestAnimationFrame loop while any spinner
// is on screen and exposes the timestamp as r.now; the phase derives from it, so
// the animation is purely a function of time (no per-widget state).
import { KIND, ATTR } from '../protocol.js';
import { register } from '../registry.js';

const N = 8;             // dots around the ring
const PERIOD = 900;      // ms for one full revolution

register(KIND.spinner, {
  draw(node, r) {
    const x = r.attr(node, ATTR.x, 0), y = r.attr(node, ATTR.y, 0);
    const w = r.attr(node, ATTR.w, 36), h = r.attr(node, ATTR.h, 36);
    const cx = x + w / 2, cy = y + h / 2;
    const size = Math.min(w, h);
    const dotR = Math.max(1.5, size * 0.10);
    const ring = size / 2 - dotR;                 // dot-center radius
    const base = r.color(node, ATTR.fg, r.theme.accent);
    const now = r.now ?? 0;
    const head = (now / PERIOD) * N;              // bright spot position (continuous)
    for (let i = 0; i < N; i++) {
      const a = -Math.PI / 2 + (i / N) * Math.PI * 2;   // start at top, clockwise
      const dx = cx + ring * Math.cos(a), dy = cy + ring * Math.sin(a);
      const d = ((i - head) % N + N) % N;         // 0 at the head, grows backwards
      const alpha = Math.max(0.15, 1 - d / N);    // comet trail
      r.drawPrim(r.pass, dx - dotR, dy - dotR, dotR * 2, dotR * 2, [base[0], base[1], base[2], alpha], { radius: dotR });
    }
  },
  measure(node) {
    return { w: Number(node.attrs.get(ATTR.w) ?? 36), h: Number(node.attrs.get(ATTR.h) ?? 36) };
  },
});
