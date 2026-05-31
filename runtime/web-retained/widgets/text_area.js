// text_area (kind 18): a multi-line text field. Value + caret are host-captured
// via a hidden <textarea> (Enter inserts a newline); q64 reads the value back as
// a `text: str` param. We greedy word-wrap to the box width (honoring explicit
// newlines), draw each line clipped to the box, and place the caret at the
// element's selectionStart. Tap-to-position is provided via caretAt().
//
// v1 scope: top-anchored, no internal vertical scroll — lines past the bottom
// are clipped. Long unbreakable words overflow horizontally.
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

function advance(r, s) {
  if (!s) return 0;
  const g = r.glyphForStr(s, FONT);
  return g ? g.w - 2 * (g.pad || 0) : 0;
}

function indexForX(r, s, x) {
  if (x <= 0) return 0;
  let prev = 0;
  for (let i = 1; i <= s.length; i++) {
    const adv = advance(r, s.slice(0, i));
    if (x < (prev + adv) / 2) return i - 1;
    prev = adv;
  }
  return s.length;
}

// Greedy word-wrap to innerW, honoring explicit '\n'. Returns visual lines as
// { text, start } where start is the source index of the line's first char — so
// a tap (row, x) maps back to an absolute caret index, and the caret index maps
// to a row.
function wrap(r, text, innerW) {
  const out = [];
  let pos = 0;
  for (const para of text.split('\n')) {
    if (para === '') { out.push({ text: '', start: pos }); }
    else {
      let line = '', lineStart = pos, wpos = pos;
      for (const word of para.split(' ')) {
        const trial = line ? line + ' ' + word : word;
        if (line && advance(r, trial) > innerW) { out.push({ text: line, start: lineStart }); line = word; lineStart = wpos; }
        else line = trial;
        wpos += word.length + 1;             // + the separating space
      }
      out.push({ text: line, start: lineStart });
    }
    pos += para.length + 1;                  // + the '\n'
  }
  return out;
}

// The visual row holding source index `idx` (last line whose start <= idx).
function rowOf(lines, idx) {
  let row = 0;
  for (let i = 0; i < lines.length; i++) if (lines[i].start <= idx) row = i;
  return row;
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
    const ink = value ? r.theme.fg : r.theme.track;
    const innerW = g.w - 2 * PAD;
    const innerLeft = g.x + PAD;
    const maxLines = Math.max(1, Math.floor((g.h - 2 * PADV) / LINE));

    const lines = showStr ? wrap(r, showStr, innerW) : [{ text: '', start: 0 }];
    r.clip({ x: g.x, y: g.y, w: g.w, h: g.h });
    for (let i = 0; i < lines.length && i < maxLines; i++) {
      const line = lines[i].text;
      if (!line) continue;
      const glyph = r.glyphForStr(line, FONT);
      if (!glyph) continue;
      const pad = glyph.pad ?? 0;
      const ly = g.y + PADV + i * LINE;
      r.drawPrim(r.pass, innerLeft - pad, ly + (LINE - glyph.h) / 2, glyph.w, glyph.h, ink, { texView: glyph.view });
    }
    r.unclip();

    // Caret at the element's selectionStart (mapped to row + x), else end.
    if (focused && r.caretVisible()) {
      const sel = r.selStart(node);
      const idx = sel != null ? Math.min(sel, value.length) : value.length;
      const row = value ? Math.min(rowOf(lines, idx), maxLines - 1) : 0;
      const colX = value ? advance(r, value.slice(lines[row].start, idx)) : 0;
      const cx = innerLeft + colX;
      const cy = g.y + PADV + row * LINE;
      const ch = FONT;
      r.drawPrim(r.pass, cx, cy + (LINE - ch) / 2, 2, ch, r.theme.fg, {});
    }
  },
  hit(node, px, py, r) {
    const g = geom(node, r);
    return px >= g.x && px <= g.x + g.w && py >= g.y && py <= g.y + g.h;
  },
  // Map a tap (px, py) to an absolute caret index: pick the row by y, the column
  // by x within that line, then offset by the line's source start.
  caretAt(node, px, py, r) {
    const g = geom(node, r);
    const value = r.textValue(node);
    if (!value) return 0;
    const innerW = g.w - 2 * PAD;
    const lines = wrap(r, value, innerW);
    let row = Math.floor((py - (g.y + PADV)) / LINE);
    row = Math.max(0, Math.min(row, lines.length - 1));
    const col = indexForX(r, lines[row].text, px - (g.x + PAD));
    return lines[row].start + col;
  },
  measure(node) {
    return { w: Number(node.attrs.get(ATTR.w) ?? 300), h: Number(node.attrs.get(ATTR.h) ?? 120) };
  },
});
