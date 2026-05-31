// switch (kind 8): boolean toggle as a pill track with a sliding knob.
// State is read from ATTR.checked (0=off, 1=on); the wasm flips it on press.
import { KIND, ATTR } from '../protocol.js';
import { register } from '../registry.js';

register(KIND.switch, {
  draw(node, r) {
    const x = r.attr(node, ATTR.x, 0), y = r.attr(node, ATTR.y, 0);
    const w = r.attr(node, ATTR.w, 48), h = r.attr(node, ATTR.h, 28);
    const on = r.attr(node, ATTR.checked, 0) !== 0;

    // Track: full capsule.
    const track = on ? r.theme.accent : r.theme.track;
    r.drawPrim(r.pass, x, y, w, h, track, { radius: h / 2 });

    // Knob: a circle inset by a few px, slid left/off or right/on.
    const inset = 3;
    const knob = h - inset * 2;
    const knobX = on ? x + w - inset - knob : x + inset;
    const knobY = y + inset;
    r.drawPrim(r.pass, knobX, knobY, knob, knob, r.theme.fg, { radius: knob / 2 });
  },
  hit(node, px, py, r) {
    const x = r.attr(node, ATTR.x, 0), y = r.attr(node, ATTR.y, 0);
    const w = r.attr(node, ATTR.w, 48), h = r.attr(node, ATTR.h, 28);
    return px >= x && px <= x + w && py >= y && py <= y + h;
  },
});
