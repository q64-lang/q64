// Headless SOFTWARE renderer for the retained QView gallery.
//
// Walks the SAME retained tree the WebGPU host builds (from the real compiled
// screen.wasm), driving the SAME widget modules — but the render context's
// drawPrim() emits SVG instead of GPU draws. resvg rasterizes the SVG to a PNG
// so the UI can be inspected headlessly (and snapshot-diffed against the GPU
// renderer, which is ground truth — see docs).
//
// Not pixel-identical to WebGPU (resvg text vs MSDF, simpler AA), but
// STRUCTURALLY faithful: positions, sizes, colors, text, z-order, popups. That's
// what catches layout/visibility bugs.
//
//   node softrender.mjs [out.png] [--platform ios|android|desktop] [--width 412] [--height 760]
import { readFileSync, writeFileSync } from 'node:fs';
import { Resvg } from '@resvg/resvg-js';
import { KIND, ATTR, SURFACE, unpackColor } from './protocol.js';
import { widgetFor } from './widgets.js';
import { themeFor } from './theme.js';

const args = process.argv.slice(2);
const out = args.find((a) => a.endsWith('.png')) || 'gallery.png';
const opt = (name, dflt) => { const i = args.indexOf(`--${name}`); return i >= 0 ? args[i + 1] : dflt; };
const PLATFORM = opt('platform', 'ios');
const W = Number(opt('width', 412));
const H = Number(opt('height', 820));
const THEME = themeFor(PLATFORM);

// Host glyph catalog (mirror of app.js). Kept in sync by hand for now.
const CATALOG_BASE = 1000;
const CATALOG = [
  'Widget gallery', 'Label', 'Button', 'Checkbox', 'Switch', 'Radio A', 'Radio B',
  'Slider', 'Progress', 'Dropdown', 'Box', 'Tap +1', 'iOS', 'Android', 'Windows',
  'Linux', 'Grouped', 'In a group', 'Long Click', 'Cut', 'Copy', 'Paste',
];

// ---- build the retained tree from the real wasm -----------------------------
const nodes = new Map();
nodes.set(0, { id: 0, kind: -1, parent: -1, attrs: new Map(), children: [], handlers: new Map() });
let openDropdownId = null;
function ops() {
  return { env: { out: () => {} }, qview: {
    create: (id, k, p) => { id = Number(id); const n = { id, kind: Number(k), parent: Number(p), attrs: new Map(), children: [], handlers: new Map() }; nodes.set(id, n); (nodes.get(Number(p)) ?? nodes.get(0)).children.push(id); },
    set_attr: (id, a, v) => nodes.get(Number(id))?.attrs.set(Number(a), v),
    remove: () => {}, on: (id, e, h) => nodes.get(Number(id))?.handlers.set(Number(e), Number(h)),
    present: () => {},
  } };
}

// ---- SVG emitter ------------------------------------------------------------
const svg = [];
const f2 = (n) => Number(n.toFixed(2));
const rgba = (c) => `rgba(${Math.round(c[0]*255)},${Math.round(c[1]*255)},${Math.round(c[2]*255)},${f2(c[3])})`;
function rect(x, y, w, h, fill, { radius = 0, border = 0, borderColor } = {}) {
  if (w <= 0 || h <= 0) return;
  const stroke = border > 0 && borderColor ? ` stroke="${rgba(borderColor)}" stroke-width="${border}"` : '';
  svg.push(`<rect x="${f2(x)}" y="${f2(y)}" width="${f2(w)}" height="${f2(h)}" rx="${f2(radius)}" fill="${rgba(fill)}"${stroke}/>`);
}
// Text: resvg renders real fonts. We approximate the glyph box used by the GPU
// host (sdfTexture) — height ~17px cap, width measured by an average advance.
const FONT_PX = 17;
function textBox(str) { return { w: str.length * FONT_PX * 0.55, h: FONT_PX * 1.1 }; }
function drawText(x, y, str, color) {
  // y is the glyph box top (host convention); SVG text baseline ~ +cap.
  svg.push(`<text x="${f2(x)}" y="${f2(y + FONT_PX)}" font-family="system-ui, sans-serif" font-size="${FONT_PX}" fill="${rgba(color)}">${esc(str)}</text>`);
}
const esc = (s) => String(s).replace(/[<>&]/g, (c) => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;' }[c]));

// A glyph object compatible with what widgets expect from r.textFor/sdfText:
// { w, h, view, _str } — view is unused in SVG; we stash the string to draw.
const glyph = (str) => { const b = textBox(str); return { w: b.w, h: b.h, _str: str }; };
function glyphForCatalog(textId) {
  const n = Number(textId);
  return glyph((n >= CATALOG_BASE && n - CATALOG_BASE < CATALOG.length) ? CATALOG[n - CATALOG_BASE] : String(n));
}
function glyphForNode(node) {
  const id = node.attrs.get(ATTR.text_id);
  if (id === undefined) return null;
  return glyphForCatalog(id);
}

// The render context: same shape as the GPU host's, but drawPrim -> SVG.
const SURFACE_KEY = { [SURFACE.none]: 'none', [SURFACE.surface]: 'surface', [SURFACE.material]: 'material', [SURFACE.materialThin]: 'materialThin', [SURFACE.scrim]: 'scrim' };
const r = {
  theme: THEME, platform: PLATFORM, pass: null,
  attr: (n, a, d) => { const v = n.attrs.get(a); return v === undefined ? d : Number(v); },
  color: (n, a, d) => { const v = n.attrs.get(a); return v === undefined ? d : unpackColor(v); },
  surfaceFill: (n, d) => {
    const role = n.attrs.get(ATTR.surface);
    if (role !== undefined) { const k = SURFACE_KEY[Number(role)]; if (k === 'none') return null; if (k) return THEME[k] ?? d; }
    const lit = n.attrs.get(ATTR.fill); return lit === undefined ? d : unpackColor(lit);
  },
  isPressed: () => false, isOpen: (id) => id === openDropdownId,
  // Glyph objects carry the string on `.view`, so a widget's `{ texView: g.view }`
  // hands the text to drawPrim. textFor/glyphForId/sdfText all patch `.view`.
  textFor: (n) => patchGlyph(glyphForNode(n)),
  glyphForId: (id) => patchGlyph(glyphForCatalog(id)),
  sdfText: (str) => patchGlyph(glyph(str)),
  // A glyph draw passes opts.texView = the string; else a rounded-rect.
  drawPrim: (_pass, x, y, w, h, fill, o = {}) => {
    if (o && typeof o.texView === 'string') drawText(x, y, o.texView, fill);
    else rect(x, y, w, h, fill, o);
  },
};
function patchGlyph(g) { if (g) g.view = g._str; return g; }

// ---- run ---------------------------------------------------------------------
const bytes = readFileSync(new URL('./screen.wasm', import.meta.url));
const { instance } = await WebAssembly.instantiate(bytes, ops());
instance.exports._start();

// Background + walk the tree (same order as the host).
svg.length = 0;
function walk(id) {
  const n = nodes.get(id); if (!n) return;
  if (id !== 0) { const w = widgetFor(n.kind); if (w && w.draw) w.draw(n, r); }
  for (const c of n.children) walk(c);
}
walk(0);

const doc = `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">`
  + `<rect width="${W}" height="${H}" fill="${rgba(THEME.bg)}"/>` + svg.join('') + `</svg>`;

const png = new Resvg(doc, { background: rgba(THEME.bg), fitTo: { mode: 'width', value: W } }).render().asPng();
writeFileSync(out, png);
console.log(`softrender: ${out} (${PLATFORM}, ${W}x${H}, ${nodes.size} nodes, ${svg.length} prims)`);
