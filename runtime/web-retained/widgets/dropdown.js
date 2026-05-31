// dropdown (kind 12): select-one control. A field showing the selected option +
// a chevron; tapping opens a menu of options (the shared popup primitive),
// tapping one selects it.
//
// Options model: option labels are host-catalog strings, declared by a base
// catalog id + count:
//   ATTR.min      = base text_id of the first option
//   ATTR.max      = number of options
//   ATTR.selected = selected index (-1 = none); the field text_id = base+selected.
//
// The popup itself is the reusable ../popup.js primitive (shared with future
// context menus). This widget just builds the menu SPEC (menuSpec) from its
// option range; the host draws/hit-tests it and reports the chosen catalog id.
import { KIND, ATTR } from '../protocol.js';
import { register } from '../registry.js';

let chevron = null;

const geom = (node, r) => ({
  x: r.attr(node, ATTR.x, 0), y: r.attr(node, ATTR.y, 0),
  w: r.attr(node, ATTR.w, 220), h: r.attr(node, ATTR.h, 44),
});

register(KIND.dropdown, {
  draw(node, r) {
    const { x, y, w, h } = geom(node, r);
    const open = r.isOpen && r.isOpen(node.id);
    r.drawPrim(r.pass, x, y, w, h, r.theme.surface, {
      radius: 8, border: open ? 2 : 1, borderColor: open ? r.theme.accent : r.theme.border,
    });
    const pad = 12;
    const lbl = r.textFor(node);
    if (lbl) r.drawPrim(r.pass, x + pad, y + (h - lbl.h) / 2, lbl.w, lbl.h, r.theme.fg, { texView: lbl.view });
    if (!chevron) chevron = r.sdfText('▾');
    if (chevron) r.drawPrim(r.pass, x + w - chevron.w - pad, y + (h - chevron.h) / 2, chevron.w, chevron.h, r.theme.muted, { texView: chevron.view });
  },

  hit(node, px, py, r) {
    const { x, y, w, h } = geom(node, r);
    return px >= x && px <= x + w && py >= y && py <= y + h;
  },

  // Build the shared-popup SPEC for this dropdown's options. Item id = the
  // option's catalog id (what the handler receives as the selection payload).
  menuSpec(node, r) {
    const base = r.attr(node, ATTR.min, -1);
    const count = r.attr(node, ATTR.max, 0);
    if (base < 0 || count <= 0) return null;
    const sel = r.attr(node, ATTR.selected, -1);
    const { x, y, w, h } = geom(node, r);
    const items = Array.from({ length: count }, (_, i) => ({
      id: base + i,
      glyph: r.glyphForId(base + i),
      selected: i === sel,
    }));
    return { anchor: { x, y, w, h }, items, width: w };
  },
  measure(node, r) { return { w: 220, h: 44 }; },
});
