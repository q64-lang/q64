// button (kind 6): rounded-rect SDF + centered label; press hit region.
// REFERENCE WIDGET — copy this shape for new kinds.
// The corner radius adapts per platform (r.theme.buttonShape/buttonRadius):
// iOS = rounded rect, Material = full pill. Same SDF primitive; radius differs.
import { KIND, ATTR } from '../protocol.js';
import { register } from '../registry.js';

function buttonRadius(node, r) {
  // An explicit ATTR.radius wins; otherwise the platform default. 'pill' clamps
  // to h/2 so the capsule is exact regardless of the theme's sentinel.
  const explicit = node.attrs.get(ATTR.radius);
  if (explicit !== undefined) return Number(explicit);
  const h = r.attr(node, ATTR.h, 0);
  if (r.theme.buttonShape === 'pill') return h / 2;
  return r.theme.buttonRadius ?? 14;
}

register(KIND.button, {
  draw(node, r) {
    const x = r.attr(node, ATTR.x, 0), y = r.attr(node, ATTR.y, 0);
    const w = r.attr(node, ATTR.w, 0), h = r.attr(node, ATTR.h, 0);
    const radius = buttonRadius(node, r);
    const pressed = r.isPressed(node.id);
    const fill = pressed ? r.theme.accentDim : r.color(node, ATTR.fill, r.theme.accent);
    r.drawPrim(r.pass, x, y, w, h, fill, { radius, border: 0 });
    const lbl = r.textFor(node);
    if (lbl) r.drawPrim(r.pass, x + (w - lbl.w) / 2, y + (h - lbl.h) / 2, lbl.w, lbl.h, r.theme.accentInk, { texView: lbl.view });
  },
  hit(node, px, py, r) {
    const x = r.attr(node, ATTR.x, 0), y = r.attr(node, ATTR.y, 0);
    const w = r.attr(node, ATTR.w, 0), h = r.attr(node, ATTR.h, 0);
    return px >= x && px <= x + w && py >= y && py <= y + h;
  },
});
