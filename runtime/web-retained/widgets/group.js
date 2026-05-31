// group (kind 14): a titled container — a rounded panel with a heading, holding
// sub-widgets. Like `box` it only paints its own surface + title; its children
// are real retained nodes drawn on top by the host's tree walk (so any widget
// can be grouped). Non-interactive (no hit).
//
// Attrs:
//   x/y/w/h          panel rect
//   ATTR.text_id     heading label (host catalog) — drawn inset at the top
//   ATTR.fill        panel fill (default theme.surface; ATTR.surface role also
//                    honored via r.surfaceFill for a translucent group)
//   ATTR.radius      corner radius (default 14)
//   ATTR.border_w    optional border width (default 1)
//
// The producer positions children inside the panel (Stage-1 positional layout),
// leaving room under the heading. A header inset constant is exported so the
// gallery can lay children out consistently.
import { KIND, ATTR } from '../protocol.js';
import { register } from '../registry.js';

export const HEADER_INSET = 36;   // px from the panel top to the content area

register(KIND.group, {
  draw(node, r) {
    const x = r.attr(node, ATTR.x, 0), y = r.attr(node, ATTR.y, 0);
    const w = r.attr(node, ATTR.w, 200), h = r.attr(node, ATTR.h, 120);
    const radius = r.attr(node, ATTR.radius, 14);
    const borderW = r.attr(node, ATTR.border_w, 1);
    // Panel: surface role (translucent material) over literal fill over default.
    const fill = r.surfaceFill(node, r.theme.surface) ?? [0, 0, 0, 0];
    const opts = { radius };
    if (borderW > 0) { opts.border = borderW; opts.borderColor = r.color(node, ATTR.border, r.theme.border); }
    r.drawPrim(r.pass, x, y, w, h, fill, opts);
    // Heading (uppercase-feel via the muted accent), inset top-left.
    const lbl = r.textFor(node);
    if (lbl) r.drawPrim(r.pass, x + 14, y + 12, lbl.w, lbl.h, r.theme.accent, { texView: lbl.view });
  },
});
