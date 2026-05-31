// slider (kind 10): horizontal track + filled portion + draggable knob.
// Reads min/max/value; renders the current value. ATTR.value stays producer-owned
// (the wasm owns value), but the host turns a touch/drag position into a value
// PAYLOAD via value() below and passes it to the handler, which sets ATTR.value.
// So press jumps the thumb to the touch and drag tracks the finger.
import { KIND, ATTR } from '../protocol.js';
import { register } from '../registry.js';

const TRACK_H = 6;   // thin track, vertically centered in h
const KNOB = 20;     // knob diameter

register(KIND.slider, {
  draw(node, r) {
    const x = r.attr(node, ATTR.x, 0), y = r.attr(node, ATTR.y, 0);
    const w = r.attr(node, ATTR.w, 200), h = r.attr(node, ATTR.h, 28);
    const min = r.attr(node, ATTR.min, 0);
    const max = r.attr(node, ATTR.max, 100);
    const value = r.attr(node, ATTR.value, 0);

    // Knob fraction, guarding divide-by-zero when max === min.
    const span = max - min;
    let fraction = span === 0 ? 0 : (value - min) / span;
    fraction = Math.max(0, Math.min(1, fraction));

    // Track: thin rounded-rect, vertically centered, spanning the full width.
    const trackY = y + (h - TRACK_H) / 2;
    const trackR = TRACK_H / 2;
    r.drawPrim(r.pass, x, trackY, w, TRACK_H, r.theme.track, { radius: trackR });

    // Knob sits inside the track: knobX = x + fraction*(w - knob).
    const knobX = x + fraction * (w - KNOB);

    // Filled portion: from the left up to the knob center.
    const fillW = knobX + KNOB / 2 - x;
    if (fillW > 0) r.drawPrim(r.pass, x, trackY, fillW, TRACK_H, r.theme.accent, { radius: trackR });

    // Knob: circle (rounded-rect radius = knob/2) in fg with a thin border.
    const knobY = y + (h - KNOB) / 2;
    r.drawPrim(r.pass, knobX, knobY, KNOB, KNOB, r.theme.fg, { radius: KNOB / 2, border: 2, borderColor: r.theme.border });
  },
  hit(node, px, py, r) {
    // A press anywhere on the slider row counts (whole track bounds).
    const x = r.attr(node, ATTR.x, 0), y = r.attr(node, ATTR.y, 0);
    const w = r.attr(node, ATTR.w, 200), h = r.attr(node, ATTR.h, 28);
    return px >= x && px <= x + w && py >= y && py <= y + h;
  },
  // Map a touch x to a value in [min,max]. The usable travel is the track minus
  // the knob (the knob center ranges over x+KNOB/2 .. x+w-KNOB/2), so the ends
  // are reachable and the value matches where the knob center lands.
  value(node, px, _py, r) {
    const x = r.attr(node, ATTR.x, 0);
    const w = r.attr(node, ATTR.w, 200);
    const min = r.attr(node, ATTR.min, 0);
    const max = r.attr(node, ATTR.max, 100);
    const lo = x + KNOB / 2, hi = x + w - KNOB / 2;
    let frac = hi > lo ? (px - lo) / (hi - lo) : 0;
    frac = Math.max(0, Math.min(1, frac));
    return Math.round(min + frac * (max - min));
  },
});
