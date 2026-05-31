// text_area (kind 18): a multi-line text field. Like text_input, the VALUE is
// host-owned (captured via a hidden <textarea>, so Enter inserts a newline), and
// q64 can read it back as a `text: str` param. We wrap the text to the box width
// (greedy word-wrap, honoring explicit '\n') and draw each line; the caret sits
// at the end of the last line while focused.
//
// v1 scope: top-anchored, no internal vertical scroll — lines past the box
// bottom are clipped. Long unbreakable words overflow horizontally.
import { KIND, ATTR } from '../protocol.js';
import { register } from '../registry.js';

const PAD = 12;        // inner horizontal padding
const PADV = 10;       // inner top padding
const FONT = 16;       // text size (px)
const LINE = 22;       // line advance (px)

const geom = (node, r) => ({
  x: r.attr(node, ATTR.x, 0), y: r.attr(node, ATTR.y, 0),
  w: r.attr(node, ATTR.w, 300), h: r.attr(node, ATTR.h, 120),
});

// Advance width (ink, not the padded SDF quad) of a string at FONT.
function advance(r, s) {
  const g = s ? r.glyphForStr(s, FONT) : null;
  return g ? g.w - 2 * (g.pad || 0) : 0;
}

// Greedy word-wrap to innerW, honoring explicit newlines. Returns an array of
// lines (each a string; '' for a blank line).
function wrap(r, text, innerW) {
  const lines = [];
  for (const para of text.split('\n')) {
    if (para === '') { lines.push(''); continue; }
    let line = '';
    for (const word of para.split(' ')) {
      const trial = line ? line + ' ' + word : word;
      if (line && advance(r, trial) > innerW) { lines.push(line); line = word; }
      else line = trial;
    }
    lines.push(line);
  }
  return lines;
}

register(KIND.text_area, {
  draw(node, r) {
    const g = geom(node, r);
    const focused = r.isFocused(node.id);
    const radius = Number(node.attrs.get(ATTR.radius) ?? r.theme.buttonRadius ?? 10);
    const bg = r.surfaceFill(node, r.theme.surface) ?? r.theme.surface;
    const borderColor = focused ? r.theme.accent : r.theme.border;
    r.drawPrim(r.pass, g.x, g.y, g.w, g.h, bg, { radius, border: focused ? 2 : 1, borderColor });

    const value = r.textValue(node);
    const placeholder = r.textPlaceholder(node);
    const showStr = value || placeholder;
    const ink = value ? r.theme.fg : r.theme.track;     // placeholder = muted
    const innerW = g.w - 2 * PAD;
    const innerLeft = g.x + PAD;
    const maxLines = Math.max(1, Math.floor((g.h - 2 * PADV) / LINE));

    const lines = showStr ? wrap(r, showStr, innerW) : [''];
    for (let i = 0; i < lines.length && i < maxLines; i++) {
      const line = lines[i];
      if (!line) continue;
      const glyph = r.glyphForStr(line, FONT);
      if (!glyph) continue;
      const pad = glyph.pad ?? 0;
      const ly = g.y + PADV + i * LINE;
      r.drawPrim(r.pass, innerLeft - pad, ly + (LINE - glyph.h) / 2, glyph.w, glyph.h, ink, { texView: glyph.view });
    }
    // Caret at the end of the last visible VALUE line (top-left when empty).
    if (focused && r.caretVisible()) {
      const row = value ? Math.min(lines.length - 1, maxLines - 1) : 0;
      const cx = innerLeft + (value ? advance(r, lines[row]) : 0);
      const cy = g.y + PADV + row * LINE;
      const ch = FONT;
      r.drawPrim(r.pass, cx + 1, cy + (LINE - ch) / 2, 2, ch, r.theme.fg, {});
    }
  },
  hit(node, px, py, r) {
    const g = geom(node, r);
    return px >= g.x && px <= g.x + g.w && py >= g.y && py <= g.y + g.h;
  },
  measure(node) {
    return { w: Number(node.attrs.get(ATTR.w) ?? 300), h: Number(node.attrs.get(ATTR.h) ?? 120) };
  },
});
