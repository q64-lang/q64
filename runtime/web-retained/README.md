# runtime/web-retained — QView Stage-1 retained host (WebGPU)

The **retained-mode** QView host: implements the mutation protocol from
[`spec/qview-protocol.md`](../../spec/qview-protocol.md). Unlike the immediate-mode
POC in [`../web`](../web) (which re-emits + repaints the whole scene every frame),
this host keeps a **retained node tree** (`node_id → record`) that a q64-compiled
wasm builds once and then mutates **surgically** via `set_attr` on the exact node.
Node identity (the basis for future focus/caret/scroll) is the `node_id`,
preserved across frames.

## Files

| File | Role | Who edits it |
|---|---|---|
| `protocol.js` | The **frozen** op/enum contract (KIND/ATTR/EVENT). Append-only. | protocol owner only |
| `gpu.js` | WebGPU device + procedural-SDF pipeline + SDF text. Reused from the POC. | rarely |
| `widgets.js` | **Widget draw registry.** One `register(KIND.x, {draw, hit})` per kind. | **widget authors** |
| `app.js` | Retained tree, the five ops, render walk, input → `on_event`. | host owner |
| `screen.q` | The q64 reference screen (label + button) over the protocol. | examples |
| `test-headless.mjs` | Node test of the protocol against the real `screen.wasm`. | CI |

## Adding a widget

Widgets live entirely in `widgets.js` and never touch the protocol or op layer:

```js
import { KIND, ATTR } from './protocol.js';
register(KIND.checkbox, {
  draw(node, r) {
    const x = r.attr(node, ATTR.x, 0), y = r.attr(node, ATTR.y, 0);
    const on = r.attr(node, ATTR.checked, 0) === 1;
    r.drawPrim(r.pass, x, y, 24, 24, on ? r.theme.accent : [0,0,0,0],
      { radius: 6, border: 2, borderColor: r.theme.border });
    // ... checkmark ...
  },
  hit(node, px, py, r) { /* return true if (px,py) inside */ },
});
```

The render context `r` gives you: `pass`, `drawPrim`, `sdfText`, `theme`,
`attr(node, ATTR, dflt)`, `color(node, ATTR, dflt)`, `textFor(node)`,
`isPressed(id)`. Read kind/attr/event tags from `protocol.js` — never hardcode
integers. New kinds/attrs/events are **appended** to `protocol.js` (+ the spec),
never renumbered.

## Build & run

```sh
./build.sh            # q64 emit screen.q -> screen.wasm
./build.sh --serve    # + serve on http://localhost:8787 (open in a WebGPU browser)
node test-headless.mjs   # verify the protocol against the real wasm (no GPU)
```

WebGPU is required (iPad Safari 18+, modern Chrome/Firefox). There is no DOM
fallback — per [`spec/reactivity.md`](../../spec/reactivity.md) the substrate is
WebGPU-only; the same scene graph + protocol target native (wgpu/Dawn) later.
