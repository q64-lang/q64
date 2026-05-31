// row (kind 1 = HStack), column (kind 2 = VStack), stack (kind 3 = ZStack):
// layout containers. The arrange engine (arrange.js) positions their children
// along the main axis with ATTR.gap, aligns on the cross axis (ATTR.align),
// inside ATTR.pad — the producer no longer assigns child x/y.
//
// A container draws a background only when it carries a fill or a surface role,
// so a stack can BE a panel that wraps its measured content (e.g. the outer body
// VStack). Otherwise it's transparent (pure layout). Non-interactive (no hit).
import { KIND, ATTR } from '../protocol.js';
import { register } from '../registry.js';

function container(name) {
  return {
    _layout: name,
    draw(node, r) {
      // Paint only when a fill or surface role is set; the arrange pass has sized
      // this stack to its content, so the panel wraps its children exactly.
      if (!node.attrs.has(ATTR.surface) && !node.attrs.has(ATTR.fill)) return;
      const fill = r.surfaceFill(node, null);
      if (fill === null) return;
      const x = r.attr(node, ATTR.x, 0), y = r.attr(node, ATTR.y, 0);
      const w = r.attr(node, ATTR.w, 0), h = r.attr(node, ATTR.h, 0);
      const radius = r.attr(node, ATTR.radius, 0);
      const borderW = r.attr(node, ATTR.border_w, 0);
      const opts = { radius };
      if (borderW > 0) { opts.border = borderW; opts.borderColor = r.color(node, ATTR.border, r.theme.border); }
      r.drawPrim(r.pass, x, y, w, h, fill, opts);
    },
  };
}

register(KIND.row, container('row'));
register(KIND.column, container('column'));
register(KIND.stack, container('stack'));
