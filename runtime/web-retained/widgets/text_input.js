// text_input (kind 17): a single-line text field. The VALUE is host-owned — the
// host captures keystrokes via a hidden <input> (for the iOS/Android soft
// keyboard + IME) and stores the string on the node (set_text op / live edits);
// q64 reads it back as a `text: str` handler param to validate. We draw the
// box, the value (or a dimmed placeholder), and a caret when focused.
//
// v1 scope: left-aligned, no horizontal scroll or mid-text caret — the caret
// sits after the value. Long text overflows the field (revisit with clipping).
import { KIND, ATTR } from '../protocol.js';
import { register } from '../registry.js';

const PAD = 12;        // inner horizontal padding
const FONT = 17;       // text size (px)

const geom = (node, r) => ({
  x: r.attr(node, ATTR.x, 0), y: r.attr(node, ATTR.y, 0),
  w: r.attr(node, ATTR.w, 240), h: r.attr(node, ATTR.h, 44),
});

register(KIND.text_input, {
  draw(node, r) {
    const g = geom(node, r);
    const focused = r.isFocused(node.id);
    const radius = Number(node.attrs.get(ATTR.radius) ?? r.theme.buttonRadius ?? 10);
    // Field background + border (accent + thicker when focused).
    const bg = r.surfaceFill(node, r.theme.surface) ?? r.theme.surface;
    const borderColor = focused ? r.theme.accent : r.theme.border;
    r.drawPrim(r.pass, g.x, g.y, g.w, g.h, bg, { radius, border: focused ? 2 : 1, borderColor });

    // Value if present, else the dimmed placeholder.
    const value = r.textValue(node);
    const placeholder = r.textPlaceholder(node);
    const str = value || placeholder;
    const glyph = str ? r.glyphForStr(str, FONT) : null;
    let caretX = g.x + PAD;
    if (glyph) {
      const ty = g.y + (g.h - glyph.h) / 2;
      const ink = value ? r.theme.fg : r.theme.track;     // placeholder = muted
      r.drawPrim(r.pass, g.x + PAD, ty, glyph.w, glyph.h, ink, { texView: glyph.view });
      if (value) caretX = g.x + PAD + glyph.w;
    }
    // A steady caret bar after the value while focused (no blink in v1).
    if (focused) {
      const ch = Math.round(g.h * 0.5);
      r.drawPrim(r.pass, caretX + 1, g.y + (g.h - ch) / 2, 2, ch, r.theme.accent, {});
    }
  },
  hit(node, px, py, r) {
    const g = geom(node, r);
    return px >= g.x && px <= g.x + g.w && py >= g.y && py <= g.y + g.h;
  },
  measure(node) {
    return { w: Number(node.attrs.get(ATTR.w) ?? 240), h: Number(node.attrs.get(ATTR.h) ?? 44) };
  },
});
