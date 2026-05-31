// icon (kind 19): a vector icon (Lucide) from the host ICONS catalog, referenced
// by ATTR.icon and tinted by ATTR.fg (default the theme fg). Rendered as an SDF
// (see gpu.js iconSdf) so it stays crisp at any size. The ink is centered in the
// node's box; the SDF quad's transparent pad overflows harmlessly.
import { KIND, ATTR } from '../protocol.js';
import { register } from '../registry.js';

register(KIND.icon, {
  draw(node, r) {
    const id = node.attrs.get(ATTR.icon);
    if (id === undefined) return;
    const x = r.attr(node, ATTR.x, 0), y = r.attr(node, ATTR.y, 0);
    const w = r.attr(node, ATTR.w, 24), h = r.attr(node, ATTR.h, 24);
    const g = r.iconGlyph(id, Math.min(w, h));
    if (!g) return;
    const color = r.color(node, ATTR.fg, r.theme.fg);
    r.drawPrim(r.pass, x + (w - g.w) / 2, y + (h - g.h) / 2, g.w, g.h, color, { texView: g.view });
  },
  measure(node) {
    return { w: Number(node.attrs.get(ATTR.w) ?? 24), h: Number(node.attrs.get(ATTR.h) ?? 24) };
  },
});
