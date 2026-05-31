// box (kind 0): base container surface — a rounded-rect SDF panel.
// Draws its own background (+ optional centered ATTR.text_id label); children are
// drawn by the host's tree walk. A box that declares an option range (ATTR.min =
// base catalog id, ATTR.max = count) becomes a CONTEXT-MENU surface: long-press
// / right-click raises a menu of those options (the shared popup primitive). It
// gains hit() in that case so the host can target it.
import { KIND, ATTR } from '../protocol.js';
import { register } from '../registry.js';

const geom = (node, r) => ({
  x: r.attr(node, ATTR.x, 0), y: r.attr(node, ATTR.y, 0),
  w: r.attr(node, ATTR.w, 120), h: r.attr(node, ATTR.h, 80),
});
const hasMenu = (node, r) => r.attr(node, ATTR.min, -1) >= 0 && r.attr(node, ATTR.max, 0) > 0;

register(KIND.box, {
  draw(node, r) {
    const { x, y, w, h } = geom(node, r);
    const radius = r.attr(node, ATTR.radius, 12);
    const borderW = r.attr(node, ATTR.border_w, 0);
    // surfaceFill honors a semantic ATTR.surface role (theme material/scrim)
    // over a literal ATTR.fill; a 'none' role means draw no background.
    const fill = r.surfaceFill(node, r.theme.surface);
    const hasFill = !(fill === null && borderW <= 0);
    const opts = { radius };
    if (borderW > 0) { opts.border = borderW; opts.borderColor = r.color(node, ATTR.border, r.theme.border); }
    if (hasFill) r.drawPrim(r.pass, x, y, w, h, fill ?? [0, 0, 0, 0], opts);
    // Optional centered label (e.g. a "Long Click" hint).
    const lbl = r.textFor(node);
    if (lbl) r.drawPrim(r.pass, x + (w - lbl.w) / 2, y + (h - lbl.h) / 2, lbl.w, lbl.h, r.theme.muted, { texView: lbl.view });
  },

  // Only hit-testable when it can raise a context menu (otherwise a plain panel).
  hit(node, px, py, r) {
    if (!hasMenu(node, r)) return false;
    const { x, y, w, h } = geom(node, r);
    return px >= x && px <= x + w && py >= y && py <= y + h;
  },

  // Context menu = the option range, as popup items (item id = catalog id).
  contextMenu(node, r) {
    const base = r.attr(node, ATTR.min, -1);
    const count = r.attr(node, ATTR.max, 0);
    if (base < 0 || count <= 0) return null;
    const sel = r.attr(node, ATTR.selected, -1);
    const items = Array.from({ length: count }, (_, i) => ({
      id: base + i, glyph: r.glyphForId(base + i), selected: base + i === sel,
    }));
    return { items, width: 200 };
  },
});
