// divider (kind 13): a thin separator line (hairline rule). Spans its width at
// its y; a leaf, non-interactive (no hit). Color = ATTR.fg, else theme border;
// thickness = ATTR.h (default 1px), inset by ATTR.x .. x+w.
import { KIND, ATTR } from '../protocol.js';
import { register } from '../registry.js';

register(KIND.divider, {
  draw(node, r) {
    const x = r.attr(node, ATTR.x, 0), y = r.attr(node, ATTR.y, 0);
    const w = r.attr(node, ATTR.w, 200);
    const t = Math.max(1, r.attr(node, ATTR.h, 1));   // thickness
    const col = r.color(node, ATTR.fg, r.theme.border);
    r.drawPrim(r.pass, x, y, w, t, col, { radius: t / 2 });
  },
});
