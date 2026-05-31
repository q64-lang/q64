// text_input (kind 17): a single-line text field. The VALUE and the caret/
// selection are host-captured via a hidden <input> (for the soft keyboard +
// IME); q64 reads the value back as a `text: str` param. We draw the box, the
// value (or a dimmed placeholder), and the caret at the element's selectionStart
// while focused. The text scrolls horizontally to keep the caret in view and is
// clipped to the box. Tap-to-position is provided via caretAt().
import { KIND, ATTR } from '../protocol.js';
import { register } from '../registry.js';

const PAD = 12;        // inner horizontal padding
const FONT = 17;       // text size (px)

const geom = (node, r) => ({
  x: r.attr(node, ATTR.x, 0), y: r.attr(node, ATTR.y, 0),
  w: r.attr(node, ATTR.w, 240), h: r.attr(node, ATTR.h, 44),
});

// Ink advance width (not the padded SDF quad) of a string at FONT.
function advance(r, s) {
  if (!s) return 0;
  const g = r.glyphForStr(s, FONT);
  return g ? g.w - 2 * (g.pad || 0) : 0;
}

// The character index whose boundary is nearest x (px from the text's start).
function indexForX(r, value, x) {
  if (x <= 0) return 0;
  let prev = 0;
  for (let i = 1; i <= value.length; i++) {
    const adv = advance(r, value.slice(0, i));
    if (x < (prev + adv) / 2) return i - 1;
    prev = adv;
  }
  return value.length;
}

register(KIND.text_input, {
  draw(node, r) {
    const g = geom(node, r);
    const focused = r.isFocused(node.id);
    const radius = Number(node.attrs.get(ATTR.radius) ?? r.theme.buttonRadius ?? 10);
    const bg = r.surfaceFill(node, r.theme.surface) ?? r.theme.surface;
    const borderColor = focused ? r.theme.accent : r.theme.border;
    r.drawPrim(r.pass, g.x, g.y, g.w, g.h, bg, { radius, border: focused ? 2 : 1, borderColor });

    const value = r.textValue(node);
    const placeholder = r.textPlaceholder(node);
    const innerLeft = g.x + PAD;
    const innerW = g.w - 2 * PAD;

    // Caret index from the hidden element (else end); its x within the text.
    const cs = r.selStart(node);
    const caretIdx = focused && cs != null ? Math.min(cs, value.length) : value.length;
    const caretAdv = advance(r, value.slice(0, caretIdx));
    const totalAdv = advance(r, value);

    // Horizontal scroll: keep the caret inside the inner box; never scroll past
    // the text end + a small margin. Only the value scrolls (placeholder = 0).
    let sx = node._sx || 0;
    const M = 2;
    if (caretAdv - sx > innerW - M) sx = caretAdv - innerW + M;
    if (caretAdv - sx < 0) sx = caretAdv;
    sx = Math.max(0, Math.min(sx, Math.max(0, totalAdv - innerW + M)));
    if (!focused) sx = 0;
    node._sx = sx;

    // Selection range (highlight behind the text); collapsed = just a caret.
    const sel = focused ? r.selRange(node) : null;
    const hasSel = sel && sel.end > sel.start && value;

    r.clip({ x: innerLeft, y: g.y, w: innerW, h: g.h });
    // Selection highlight (translucent accent), behind the text.
    if (hasSel) {
      const a = r.theme.accent;
      const hl = [a[0], a[1], a[2], 0.3];
      const x0 = innerLeft + advance(r, value.slice(0, sel.start)) - sx;
      const x1 = innerLeft + advance(r, value.slice(0, sel.end)) - sx;
      const hh = Math.round(g.h * 0.62);
      r.drawPrim(r.pass, x0, g.y + (g.h - hh) / 2, Math.max(1, x1 - x0), hh, hl, { radius: 2 });
    }
    // Text (value or placeholder), shifted by -sx.
    const str = value || placeholder;
    const glyph = str ? r.glyphForStr(str, FONT) : null;
    if (glyph) {
      const pad = glyph.pad ?? 0;
      const ty = g.y + (g.h - glyph.h) / 2;
      const ink = value ? r.theme.fg : r.theme.track;
      r.drawPrim(r.pass, innerLeft - pad - (value ? sx : 0), ty, glyph.w, glyph.h, ink, { texView: glyph.view });
    }
    r.unclip();
    // Blinking caret at the caret index (hidden while a range is selected).
    if (focused && !hasSel && r.caretVisible()) {
      const cx = innerLeft + caretAdv - sx;
      const ch = Math.round(g.h * 0.5);
      r.drawPrim(r.pass, cx, g.y + (g.h - ch) / 2, 2, ch, r.theme.fg, {});
    }
  },
  hit(node, px, py, r) {
    const g = geom(node, r);
    return px >= g.x && px <= g.x + g.w && py >= g.y && py <= g.y + g.h;
  },
  // Map a tap to a caret index (the host sets the hidden element's selection).
  caretAt(node, px, py, r) {
    const g = geom(node, r);
    const value = r.textValue(node);
    const localX = px - (g.x + PAD) + (node._sx || 0);
    return indexForX(r, value, localX);
  },
  measure(node) {
    return { w: Number(node.attrs.get(ATTR.w) ?? 240), h: Number(node.attrs.get(ATTR.h) ?? 44) };
  },
});
