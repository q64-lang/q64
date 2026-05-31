// Widget draw registry — the per-kind rendering for the retained QView host.
//
// THIS IS THE FILE WIDGET AUTHORS EXTEND. Each widget kind registers one entry:
//   register(KIND.x, { draw(node, r), hit(node, px, py)? })
// and never touches the protocol, the op application, or the event loop.
//
//   node : the retained record { id, kind, parent, attrs:Map<attr,value>,
//          children:[ids], handlers:Map<event,handlerId> }
//   r    : render context {
//            pass,                       // the WebGPU render pass
//            drawPrim, sdfText,          // gpu.js primitives (CSS px)
//            attr(node, ATTR.x, dflt),   // read an attr with a default
//            color(node, ATTR.fill, dflt:[r,g,b,a]),
//            textFor(node),              // SDF atlas for this node's text_id/value
//            isPressed(id),              // transient pointer state
//            theme,                      // shared palette (see THEME below)
//          }
//   draw returns nothing; hit returns true if (px,py) lands on the node.
//
// Reference implementations: label (kind 4) and button (kind 6). The other
// kinds (box/row/column/stack/image/checkbox/switch/radio/slider/progress/
// dropdown) are added by the parallel widget work against this same shape.
import { KIND, ATTR } from './protocol.js';

const registry = new Map();
export function register(kind, impl) { registry.set(kind, impl); }
export function widgetFor(kind) { return registry.get(kind); }

// Shared palette so widgets look consistent. Tweak in one place.
export const THEME = {
  fg:        [0.90, 0.95, 1.00, 1],
  accent:    [0.37, 0.83, 1.00, 1],
  accentDim: [0.20, 0.55, 0.75, 1],
  border:    [0.16, 0.45, 0.62, 1],
  inkOnAccent: [0.03, 0.05, 0.08, 1],
};

// ---- label (kind 4): text at (x,y) in fg color. Stage-1 text by text_id. ----
register(KIND.label, {
  draw(node, r) {
    const x = r.attr(node, ATTR.x, 0), y = r.attr(node, ATTR.y, 0);
    const lbl = r.textFor(node);
    if (!lbl) return;
    const fg = r.color(node, ATTR.fg, r.theme.fg);
    r.drawPrim(r.pass, x, y, lbl.w, lbl.h, fg, { texView: lbl.view });
  },
});

// ---- button (kind 6): rounded-rect SDF + centered label; press hit region. ----
register(KIND.button, {
  draw(node, r) {
    const x = r.attr(node, ATTR.x, 0), y = r.attr(node, ATTR.y, 0);
    const w = r.attr(node, ATTR.w, 0), h = r.attr(node, ATTR.h, 0);
    const radius = r.attr(node, ATTR.radius, 16);
    const pressed = r.isPressed(node.id);
    const fill = pressed ? r.theme.accentDim : r.color(node, ATTR.fill, r.theme.accent);
    r.drawPrim(r.pass, x, y, w, h, fill, { radius, border: 2, borderColor: r.theme.border });
    const lbl = r.textFor(node);
    if (lbl) r.drawPrim(r.pass, x + (w - lbl.w) / 2, y + (h - lbl.h) / 2, lbl.w, lbl.h, r.theme.inkOnAccent, { texView: lbl.view });
  },
  hit(node, px, py, r) {
    const x = r.attr(node, ATTR.x, 0), y = r.attr(node, ATTR.y, 0);
    const w = r.attr(node, ATTR.w, 0), h = r.attr(node, ATTR.h, 0);
    return px >= x && px <= x + w && py >= y && py <= y + h;
  },
});
