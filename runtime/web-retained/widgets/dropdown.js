// dropdown (kind 12): select-one control. Rounded field + selected label + chevron.
// Interactive: hit() covers the field so it receives press.
import { KIND, ATTR } from '../protocol.js';
import { register } from '../registry.js';

// Chevron caret cached once at module scope — built lazily on first draw, reused
// every frame (the glyph string never changes).
let chevron = null;

register(KIND.dropdown, {
  draw(node, r) {
    const x = r.attr(node, ATTR.x, 0), y = r.attr(node, ATTR.y, 0);
    const w = r.attr(node, ATTR.w, 200), h = r.attr(node, ATTR.h, 40);
    // selected index; -1 = none. Read for completeness/follow-up popup logic.
    const selected = r.attr(node, ATTR.selected, -1);

    // Field: rounded-rect surface with a thin border.
    r.drawPrim(r.pass, x, y, w, h, r.theme.surface, { radius: 8, border: 1, borderColor: r.theme.border });

    const pad = 10;

    // Selected label. Stage 1: the host catalog holds option strings and the
    // producer sets text_id to the selected option, so textFor() yields its glyph.
    // (Follow-up: the expanded option list / popup.) Left-aligned, vertically centered.
    const lbl = r.textFor(node);
    if (lbl) r.drawPrim(r.pass, x + pad, y + (h - lbl.h) / 2, lbl.w, lbl.h, r.theme.fg, { texView: lbl.view });

    // Chevron caret on the right, right-aligned, vertically centered.
    if (!chevron) chevron = r.sdfText('▾'); // '▾'
    if (chevron) r.drawPrim(r.pass, x + w - chevron.w - pad, y + (h - chevron.h) / 2, chevron.w, chevron.h, r.theme.muted, { texView: chevron.view });
  },
  hit(node, px, py, r) {
    const x = r.attr(node, ATTR.x, 0), y = r.attr(node, ATTR.y, 0);
    const w = r.attr(node, ATTR.w, 200), h = r.attr(node, ATTR.h, 40);
    return px >= x && px <= x + w && py >= y && py <= y + h;
  },
});
