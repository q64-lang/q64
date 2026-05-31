// box (kind 0): base container surface — a rounded-rect SDF panel.
// Draws only its own background; children are drawn by the host's tree walk.
// Not interactive — no hit().
import { KIND, ATTR } from '../protocol.js';
import { register } from '../registry.js';

register(KIND.box, {
  draw(node, r) {
    const x = r.attr(node, ATTR.x, 0), y = r.attr(node, ATTR.y, 0);
    const w = r.attr(node, ATTR.w, 120), h = r.attr(node, ATTR.h, 80);
    const radius = r.attr(node, ATTR.radius, 12);
    const borderW = r.attr(node, ATTR.border_w, 0);
    // surfaceFill honors a semantic ATTR.surface role (theme material/scrim)
    // over a literal ATTR.fill; a 'none' role means draw no background.
    const fill = r.surfaceFill(node, r.theme.surface);
    if (fill === null) { if (borderW <= 0) return; }
    const opts = { radius };
    if (borderW > 0) {
      opts.border = borderW;
      opts.borderColor = r.color(node, ATTR.border, r.theme.border);
    }
    r.drawPrim(r.pass, x, y, w, h, fill ?? [0, 0, 0, 0], opts);
  },
});
