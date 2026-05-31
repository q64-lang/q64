// label (kind 4): text at (x,y) in fg color. Stage-1 text by text_id.
// REFERENCE WIDGET — copy this shape for new kinds.
import { KIND, ATTR } from '../protocol.js';
import { register } from '../registry.js';

register(KIND.label, {
  draw(node, r) {
    const x = r.attr(node, ATTR.x, 0), y = r.attr(node, ATTR.y, 0);
    const lbl = r.textFor(node);
    if (!lbl) return;
    const fg = r.color(node, ATTR.fg, r.theme.fg);
    r.drawPrim(r.pass, x, y, lbl.w, lbl.h, fg, { texView: lbl.view });
  },
});
