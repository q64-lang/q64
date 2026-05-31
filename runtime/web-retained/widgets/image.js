// STUB — image (kind 5). Not in the first widget batch; placeholder keeps the
// registry complete. A real impl samples a host image by image_id as a textured
// quad (the one non-SDF leaf).
import { KIND, ATTR } from '../protocol.js';
import { register } from '../registry.js';
register(KIND.image, {
  draw(node, r) {
    const x = r.attr(node, ATTR.x, 0), y = r.attr(node, ATTR.y, 0);
    const w = r.attr(node, ATTR.w, 64), h = r.attr(node, ATTR.h, 64);
    r.drawPrim(r.pass, x, y, w, h, r.theme.surface, { radius: 4, border: 1, borderColor: r.theme.muted });
  },
});
