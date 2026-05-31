// dropdown (kind 12): select-one control. A field showing the selected option +
// a chevron; tapping opens a popup list of options, tapping one selects it.
//
// Stage-1 options model: the option labels are host-catalog strings. The node
// declares its options by a base catalog id + count:
//   ATTR.min      = base text_id of the first option
//   ATTR.max      = number of options
//   ATTR.selected = selected index (-1 = none); the field shows base+selected.
// The host (app.js) owns open/closed state, draws the popup via drawPopup(), and
// hit-tests rows via hitPopup() — selecting passes the chosen catalog id as the
// value payload to the wasm handler, which sets selected + the field's text_id.
import { KIND, ATTR } from '../protocol.js';
import { register } from '../registry.js';

const ROW_H = 44;        // option row height (touch target)
let chevron = null;      // cached caret glyph

const geom = (node, r) => ({
  x: r.attr(node, ATTR.x, 0), y: r.attr(node, ATTR.y, 0),
  w: r.attr(node, ATTR.w, 220), h: r.attr(node, ATTR.h, 40),
});

// Option catalog ids: [base .. base+count). base=ATTR.min, count=ATTR.max.
function options(node, r) {
  const base = r.attr(node, ATTR.min, -1);
  const count = r.attr(node, ATTR.max, 0);
  if (base < 0 || count <= 0) return [];
  return Array.from({ length: count }, (_, i) => base + i);
}

register(KIND.dropdown, {
  draw(node, r) {
    const { x, y, w, h } = geom(node, r);
    const open = r.isOpen && r.isOpen(node.id);
    // Field: rounded surface; border picks up the accent while open.
    r.drawPrim(r.pass, x, y, w, h, r.theme.surface, {
      radius: 8, border: open ? 2 : 1, borderColor: open ? r.theme.accent : r.theme.border,
    });
    const pad = 12;
    // Selected option label (field text_id is kept = base+selected by the handler).
    const lbl = r.textFor(node);
    if (lbl) r.drawPrim(r.pass, x + pad, y + (h - lbl.h) / 2, lbl.w, lbl.h, r.theme.fg, { texView: lbl.view });
    // Chevron, right-aligned.
    if (!chevron) chevron = r.sdfText('▾');
    if (chevron) r.drawPrim(r.pass, x + w - chevron.w - pad, y + (h - chevron.h) / 2, chevron.w, chevron.h, r.theme.muted, { texView: chevron.view });
  },

  // Tapping the field toggles the popup (host reads this return to manage state).
  hit(node, px, py, r) {
    const { x, y, w, h } = geom(node, r);
    return px >= x && px <= x + w && py >= y && py <= y + h;
  },

  // --- popup (drawn + hit-tested by the host only while this dropdown is open) ---
  optionRect(node, i, r) {
    const { x, y, w, h } = geom(node, r);
    return { x, y: y + h + 4 + i * ROW_H, w, h: ROW_H };
  },
  drawPopup(node, r) {
    const opts = options(node, r);
    if (opts.length === 0) return;
    const { x, y, w, h } = geom(node, r);
    const panelH = opts.length * ROW_H;
    // Panel background (material so it reads as an overlay).
    r.drawPrim(r.pass, x, y + h + 4, w, panelH, r.theme.material, { radius: 8, border: 1, borderColor: r.theme.border });
    const sel = r.attr(node, ATTR.selected, -1);
    const pad = 12;
    opts.forEach((textId, i) => {
      const rc = this.optionRect(node, i, r);
      if (i === sel) r.drawPrim(r.pass, rc.x + 4, rc.y + 3, rc.w - 8, rc.h - 6, r.theme.accentDim, { radius: 6 });
      const g = r.glyphForId(textId);
      if (g) r.drawPrim(r.pass, rc.x + pad, rc.y + (rc.h - g.h) / 2, g.w, g.h, r.theme.fg, { texView: g.view });
    });
  },
  // Returns the selected option's catalog id if (px,py) is on a row, else null.
  hitPopup(node, px, py, r) {
    const opts = options(node, r);
    for (let i = 0; i < opts.length; i++) {
      const rc = this.optionRect(node, i, r);
      if (px >= rc.x && px <= rc.x + rc.w && py >= rc.y && py <= rc.y + rc.h) return opts[i];
    }
    return null;
  },
});
