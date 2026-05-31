// progress (kind 11): determinate / indeterminate progress bar.
// Leaf, non-interactive (no hit()). Reads min/max/value; value<0 => indeterminate.
import { KIND, ATTR } from '../protocol.js';
import { register } from '../registry.js';

register(KIND.progress, {
  draw(node, r) {
    const x = r.attr(node, ATTR.x, 0), y = r.attr(node, ATTR.y, 0);
    const w = r.attr(node, ATTR.w, 200), h = r.attr(node, ATTR.h, 10);
    const min = r.attr(node, ATTR.min, 0);
    const max = r.attr(node, ATTR.max, 100);
    const value = r.attr(node, ATTR.value, 0);
    const radius = h / 2;

    // Track: full-width rounded-rect.
    r.drawPrim(r.pass, x, y, w, h, r.theme.track, { radius });

    if (value >= 0) {
      // Determinate: filled portion from the left.
      const span = max - min;
      const t = span === 0 ? 0 : Math.max(0, Math.min(1, (value - min) / span)); // guard max===min
      const fw = t * w;
      if (fw > 0) r.drawPrim(r.pass, x, y, fw, h, r.theme.accent, { radius });
    } else {
      // Indeterminate (value < 0): fixed ~30%-wide segment offset ~35% from left.
      // Follow-up: drive a time-based sweep once an animation clock exists in the host.
      const segW = w * 0.30;
      const segX = x + w * 0.35;
      r.drawPrim(r.pass, segX, y, segW, h, r.theme.accent, { radius });
    }
  },
});
