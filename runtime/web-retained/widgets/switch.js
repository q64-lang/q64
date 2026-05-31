// switch (kind 8): boolean toggle. State from ATTR.checked (0/1); the wasm flips
// it on press. Self-drawn, but the SHAPE adapts per platform (r.theme.switchVariant):
//   ios      — full capsule; off=grey track, on=green track; large white knob
//              that fills the track height (the iOS look).
//   material — pill track (off=outline+surface, on=primary); SMALL thumb when off
//              that GROWS when on; thumb sits inside the track (Material 3 look).
// One SDF rounded-rect primitive in both; only proportions/colors differ.
import { KIND, ATTR } from '../protocol.js';
import { register } from '../registry.js';

function geom(node, r) {
  return {
    x: r.attr(node, ATTR.x, 0), y: r.attr(node, ATTR.y, 0),
    w: r.attr(node, ATTR.w, 0) || (r.theme.switchVariant === 'material' ? 52 : 51),
    h: r.attr(node, ATTR.h, 0) || (r.theme.switchVariant === 'material' ? 32 : 31),
  };
}

register(KIND.switch, {
  draw(node, r) {
    const { x, y, w, h } = geom(node, r);
    const on = r.attr(node, ATTR.checked, 0) !== 0;

    if (r.theme.switchVariant === 'material') {
      // Track: outline when off (surface fill + border), primary when on.
      r.drawPrim(r.pass, x, y, w, h, on ? r.theme.on : r.theme.surface,
        { radius: h / 2, border: on ? 0 : 2, borderColor: r.theme.border });
      // Thumb: small (off) grows to large (on); colored by state.
      const small = h * 0.42, large = h * 0.72;
      const d = on ? large : small;
      const cx = on ? x + w - h / 2 : x + h / 2;          // travels end-to-end
      const thumb = on ? r.theme.accentInk : r.theme.border;
      r.drawPrim(r.pass, cx - d / 2, y + (h - d) / 2, d, d, thumb, { radius: d / 2 });
      return;
    }

    // iOS: full capsule track; knob fills the height minus a hairline inset.
    r.drawPrim(r.pass, x, y, w, h, on ? r.theme.on : r.theme.track, { radius: h / 2 });
    const inset = 2;
    const knob = h - inset * 2;
    const knobX = on ? x + w - inset - knob : x + inset;
    r.drawPrim(r.pass, knobX, y + inset, knob, knob, r.theme.knob, { radius: knob / 2 });
  },
  hit(node, px, py, r) {
    const { x, y, w, h } = geom(node, r);
    return px >= x && px <= x + w && py >= y && py <= y + h;
  },
});
