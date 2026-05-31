// button (kind 6): rounded-rect SDF + centered label; press hit region.
// REFERENCE WIDGET — copy this shape for new kinds.
import { KIND, ATTR } from '../protocol.js';
import { register } from '../registry.js';

register(KIND.button, {
  draw(node, r) {
    const x = r.attr(node, ATTR.x, 0), y = r.attr(node, ATTR.y, 0);
    const w = r.attr(node, ATTR.w, 0), h = r.attr(node, ATTR.h, 0);
    const radius = r.attr(node, ATTR.radius, 16);
    const pressed = r.isPressed(node.id);
    const fill = pressed ? r.theme.accentDim : r.color(node, ATTR.fill, r.theme.accent);
    r.drawPrim(r.pass, x, y, w, h, fill, { radius, border: 2, borderColor: r.theme.border });
    const lbl = r.textFor(node);
    if (lbl) r.drawPrim(r.pass, x + (w - lbl.w) / 2, y + (h - lbl.h) / 2, lbl.w, lbl.h, r.theme.inkOnAccent, { texView: lbl.view });
  },
  hit(node, px, py, r) {
    const x = r.attr(node, ATTR.x, 0), y = r.attr(node, ATTR.y, 0);
    const w = r.attr(node, ATTR.w, 0), h = r.attr(node, ATTR.h, 0);
    return px >= x && px <= x + w && py >= y && py <= y + h;
  },
});
