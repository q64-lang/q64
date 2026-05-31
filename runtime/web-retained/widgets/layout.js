// row (kind 1), column (kind 2), stack (kind 3): layout containers.
//
// Stage-1 layout is POSITIONAL: the producer (q64 compiler / agents) assigns
// every child an absolute x/y, and the host's tree walk draws each child at its
// own coords after the parent's draw(). So these containers do NOT reposition or
// mutate their children — a widget only ever knows its own node. They merely
// paint an optional background panel (and optional border) for the group.
//
// Stage-2 FOLLOW-UP: automatic main-axis flow. A row would lay children left to
// right, a column top to bottom, inserting ATTR.gap (= attr 19) px between them;
// stack would overlap them (z-order). That requires the host to expose child
// geometry to the container's draw (or a dedicated measure/arrange pass) since a
// widget cannot mutate sibling/child nodes here. Referencing ATTR.gap keeps the
// Stage-2 knob discoverable; it is intentionally unused in Stage 1.
import { KIND, ATTR } from '../protocol.js';
import { register } from '../registry.js';

// One DRY factory; the three kinds differ only by a debug/name tag. They share
// identical positional-container behavior in Stage 1.
function container(name) {
  return {
    _layout: name,            // debug tag (row | column | stack)
    draw(node, r) {
      // Optional background: only paint when the node carries an explicit fill.
      // r.color returns the default unchanged when the attr is absent, so pass
      // null and bail when there's nothing (or 'none') to draw.
      const fill = r.color(node, ATTR.fill, null);
      if (!fill) return;       // no fill attr -> transparent container, nothing to paint
      const x = r.attr(node, ATTR.x, 0), y = r.attr(node, ATTR.y, 0);
      const w = r.attr(node, ATTR.w, 0), h = r.attr(node, ATTR.h, 0);
      const radius = r.attr(node, ATTR.radius, 0);
      const borderW = r.attr(node, ATTR.border_w, 0);
      // Stage-2 will consume ATTR.gap here to flow children; unused in Stage 1.
      void ATTR.gap;
      const opts = { radius };
      if (borderW > 0) {
        opts.border = borderW;
        opts.borderColor = r.color(node, ATTR.border, r.theme.border);
      }
      r.drawPrim(r.pass, x, y, w, h, fill, opts);
    },
    // Containers are not interactive — no hit(). Children handle their own input.
  };
}

register(KIND.row, container('row'));
register(KIND.column, container('column'));
register(KIND.stack, container('stack'));
