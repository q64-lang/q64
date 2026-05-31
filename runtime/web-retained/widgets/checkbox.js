// checkbox (kind 7): boolean toggle as a square box with a checkmark when on.
// State is read from ATTR.checked (0=off, 1=on); the wasm flips it on press.
import { KIND, ATTR } from '../protocol.js';
import { register } from '../registry.js';

// Module-level cache for the checkmark glyph so it's built once, not per frame.
let checkGlyph = null;

register(KIND.checkbox, {
  draw(node, r) {
    const x = r.attr(node, ATTR.x, 0), y = r.attr(node, ATTR.y, 0);
    const w = r.attr(node, ATTR.w, 24), h = r.attr(node, ATTR.h, 24);
    const radius = r.attr(node, ATTR.radius, 6);
    const checked = r.attr(node, ATTR.checked, 0) !== 0;

    if (checked) {
      r.drawPrim(r.pass, x, y, w, h, r.theme.accent, { radius });
      if (!checkGlyph) checkGlyph = r.sdfText('✓');
      const g = checkGlyph;
      if (g) {
        r.drawPrim(r.pass, x + (w - g.w) / 2, y + (h - g.h) / 2, g.w, g.h, r.theme.inkOnAccent, { texView: g.view });
      }
    } else {
      r.drawPrim(r.pass, x, y, w, h, [0, 0, 0, 0], { radius, border: 2, borderColor: r.theme.border });
    }
  },
  hit(node, px, py, r) {
    const x = r.attr(node, ATTR.x, 0), y = r.attr(node, ATTR.y, 0);
    const w = r.attr(node, ATTR.w, 24), h = r.attr(node, ATTR.h, 24);
    return px >= x && px <= x + w && py >= y && py <= y + h;
  },
});
