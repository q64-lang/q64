// Popup / menu — a reusable host-side overlay primitive.
//
// One floating panel of choices: anchor it, render it on top of everything,
// pick an item, dismiss. The dropdown uses it today; a right-click / long-press
// CONTEXT MENU and overflow menus are the same primitive anchored differently
// (follow-ups). It's a HOST primitive for now; a first-class `menu` protocol
// node kind (so a producer/agent can raise menus directly) is a later step.
//
// Decoupled from any widget: callers pass a spec describing the menu and a
// select callback. The host (app.js) owns a single active popup at a time.
//
//   spec = {
//     anchor: { x, y, w, h },        // the element the menu hangs off (or a
//                                    //   zero-size rect at a point, for context)
//     items: [{ id, glyph, selected?, enabled? }],  // glyph: an SDF texture
//     width?: number,                // defaults to the anchor width (min 120)
//     onSelect: (id) => void,        // chosen item id
//   }
//
// The primitive computes item rects, draws the panel + rows, and hit-tests.
// Edge-flip + scroll for off-screen menus is a follow-up (noted below).

export const ROW_H = 44;          // item row height (touch target)
const PAD = 12;                   // horizontal text padding
const GAP = 4;                    // gap between anchor and panel
const MIN_W = 120;

function panelRect(spec) {
  const a = spec.anchor;
  const w = Math.max(spec.width ?? a.w, MIN_W);
  // Default placement: directly below the anchor. (Edge-flip/clamp: follow-up.)
  const x = a.x;
  const y = a.y + a.h + GAP;
  const h = spec.items.length * ROW_H;
  return { x, y, w, h };
}

export function itemRect(spec, i) {
  const p = panelRect(spec);
  return { x: p.x, y: p.y + i * ROW_H, w: p.w, h: ROW_H };
}

// Draw the panel + rows. `r` is the render context (drawPrim, theme).
export function drawPopup(spec, r) {
  if (!spec || spec.items.length === 0) return;
  const p = panelRect(spec);
  // Panel: translucent material so it reads as a floating overlay, with border.
  r.drawPrim(r.pass, p.x, p.y, p.w, p.h, r.theme.material, { radius: 8, border: 1, borderColor: r.theme.border });
  spec.items.forEach((it, i) => {
    const rc = itemRect(spec, i);
    if (it.selected) r.drawPrim(r.pass, rc.x + 4, rc.y + 3, rc.w - 8, rc.h - 6, r.theme.accentDim, { radius: 6 });
    if (it.glyph) {
      const fg = it.enabled === false ? r.theme.muted : r.theme.fg;
      r.drawPrim(r.pass, rc.x + PAD, rc.y + (rc.h - it.glyph.h) / 2, it.glyph.w, it.glyph.h, fg, { texView: it.glyph.view });
    }
  });
}

// Hit-test: the item id at (px,py), or null (a tap outside the panel dismisses).
export function hitPopup(spec, px, py) {
  if (!spec) return null;
  for (let i = 0; i < spec.items.length; i++) {
    const it = spec.items[i];
    if (it.enabled === false) continue;
    const rc = itemRect(spec, i);
    if (px >= rc.x && px <= rc.x + rc.w && py >= rc.y && py <= rc.y + rc.h) return it.id;
  }
  return null;
}
