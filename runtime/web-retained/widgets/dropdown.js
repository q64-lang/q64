// STUB — to be implemented. Registers placeholder(s) so the barrel resolves and
// an unimplemented widget renders visibly (dashed outline) instead of blank.
import { KIND, ATTR } from '../protocol.js';
import { register } from '../registry.js';
const placeholder = (name) => ({
  draw(node, r) {
    const x = r.attr(node, ATTR.x, 0), y = r.attr(node, ATTR.y, 0);
    const w = r.attr(node, ATTR.w, 80), h = r.attr(node, ATTR.h, 32);
    r.drawPrim(r.pass, x, y, w, h, [0, 0, 0, 0], { radius: 6, border: 1, borderColor: r.theme.muted });
  },
});
register(KIND.dropdown, placeholder('dropdown'));
