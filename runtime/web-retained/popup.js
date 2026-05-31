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
//     viewport?: { w, h },           // CSS px of the surface, for edge-flip/clamp
//     onSelect: (id) => void,        // chosen item id
//   }
//
// The primitive computes item rects (edge-aware: flips above the anchor when it
// would overflow the bottom, clamps x to stay on-screen), draws the panel +
// rows, and hit-tests. Both draw and hit go through the SAME placement, so they
// always agree. (Scrolling a list taller than the viewport: a later follow-up.)

export const ROW_H = 44;          // item row height (touch target)
const PAD = 12;                   // horizontal text padding
const GAP = 4;                    // gap between anchor and panel
const MIN_W = 120;
const MARGIN = 8;                 // keep this far from the viewport edges

// Place the panel relative to the anchor, flipping/clamping to the viewport so
// it's always fully visible. `placedAbove` lets callers know which way it went.
function panelRect(spec) {
  const a = spec.anchor;
  const vp = spec.viewport;
  const w = Math.max(spec.width ?? a.w, MIN_W);
  const h = spec.items.length * ROW_H;

  // Vertical: prefer below the anchor; flip above if it'd overflow the bottom
  // and there's more room above. Then clamp into [MARGIN, vp.h - h - MARGIN].
  const below = a.y + a.h + GAP;
  let y = below;
  let placedAbove = false;
  if (vp) {
    const roomBelow = vp.h - (a.y + a.h) - GAP;
    const roomAbove = a.y - GAP;
    if (h > roomBelow && roomAbove > roomBelow) {
      y = a.y - GAP - h;             // flip: panel sits above the anchor
      placedAbove = true;
    }
    y = Math.max(MARGIN, Math.min(y, vp.h - h - MARGIN));
  }

  // Horizontal: left-aligned to the anchor, clamped so the panel stays on-screen.
  let x = a.x;
  if (vp) x = Math.max(MARGIN, Math.min(x, vp.w - w - MARGIN));

  return { x, y, w, h, placedAbove };
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
