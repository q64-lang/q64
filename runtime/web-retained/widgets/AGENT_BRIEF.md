# Widget author brief — retained QView host

You implement ONE widget kind by editing ONLY your assigned `widgets/<kind>.js`
file(s). Do NOT touch protocol.js, registry.js, widgets.js (barrel), app.js,
gpu.js, screen.q, or any other widget's file. The protocol enums are FROZEN.

## The contract (read these first)
- `../../../spec/qview-protocol.md` — the protocol (kinds, attrs, events).
- `protocol.js` — KIND / ATTR / EVENT integer tags + unpackColor. Import tags
  from here; never hardcode integers.
- `label.js` and `button.js` — REFERENCE widgets. Copy their shape.

## What you register
```js
import { KIND, ATTR, EVENT } from '../protocol.js';
import { register } from '../registry.js';
register(KIND.<yourkind>, {
  draw(node, r) { /* draw using r.* (below) */ },
  hit(node, px, py, r) { return /* true if (px,py) is on an interactive part */ },
});
```
`hit` is optional — only for interactive widgets (controls). Return true to make
the node receive `press`; the host then calls the wasm `on_event(node, event)`.

## The render context `r`
- `r.pass` — the WebGPU render pass (pass to drawPrim).
- `r.drawPrim(pass, x, y, w, h, fill, opts)` — one quad in CSS px. `fill` is
  `[r,g,b,a]` 0..1. opts: `{ radius, border, borderColor, texView }`. With
  `texView` it draws a glyph; else a rounded-rect SDF with radius/border.
- `r.sdfText(string)` -> `{tex, view, w, h}` — rasterize text to an SDF atlas.
  Cache it; don't rebuild every frame (rebuild only when the string changes).
- `r.textFor(node)` -> the node's glyph atlas from its text_id attr (or null).
- `r.attr(node, ATTR.x, dflt)` — read an i64 attr as a Number with a default.
- `r.color(node, ATTR.fill, dflt)` — read a packed-color attr as [r,g,b,a].
- `r.isPressed(id)` — transient pointer-down state for `id`.
- `r.theme` — shared palette: fg, muted, surface, accent, accentDim, border,
  track, inkOnAccent. Use these so widgets look consistent.

## Geometry
All coords/sizes are CSS px (the host scales by DPR). `node.attrs` is a
`Map<attrTag, i64>`. Geometry attrs x/y/w/h apply to every node.

## Verify before you finish
1. `node --check widgets/<yourfile>.js` — must pass.
2. From `runtime/web-retained/`, confirm the barrel still loads and your kind
   registers:
   `node --input-type=module -e "import './widgets.js'; import {widgetFor} from './widgets.js'; import {KIND} from './protocol.js'; console.log(widgetFor(KIND.<yourkind>)?'ok':'MISSING')"`
3. Do NOT run a GPU; registration + syntax is the headless bar. Keep draw code
   pure (no top-level GPU calls — only inside draw()).

Replace the stub in your file with the real implementation. Keep it self-contained.
