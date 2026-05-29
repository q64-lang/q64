# QView reactivity & redraw — design note

> **Status: design note / draft.** Captures the model choice for reactive `state`
> in the QView UI surface and *how QView decides what to redraw*. Pairs with
> [`stdlib/reactive`](../stdlib/reactive), [`stdlib/view`](../stdlib/view)
> (`Renderer` face), [`env.md`](./env.md) (`@ui`/`@kv` effects), and the
> `state` / `@state` distinction. Not yet normative; the recommendation + staged
> path at the end is what we intend to build.

## The question

A UI is `view = f(state)`. When `state` changes, *what do we re-execute, and what
do we repaint?* The cheaper and more surgical that decision, the better the UI
scales (lists, animation, input focus, battery). This note surveys the modern
options and picks one for QView.

## The landscape — five ways to decide what to redraw

1. **Immediate mode** (Dear ImGui; our current POC). Re-run the whole UI function
   and repaint everything, every frame/interaction. *Zero bookkeeping; trivially
   correct.* But it re-executes + repaints unrelated UI and **loses node identity**
   (focus, scroll, caret, in-flight animation). Fine to prove a pipeline; wrong for
   app UIs. **This is where QView is today** (`present(full scene)` + full WebGPU pass).

2. **Retained + Virtual-DOM diff** (React, classic). Re-run components to build a
   *new* virtual tree, **diff** it against the previous one, reconcile to real nodes.
   *Simple model (`UI = f(state)`), portable.* But the diff is runtime work O(tree),
   components re-run, and you "render then throw most of it away." Mitigated with
   `memo`/keys/concurrent scheduling — and, tellingly, React's own 2024+ **compiler**
   auto-memoizes to avoid re-running/diffing unchanged parts. The VDOM is now seen as
   overhead, not an asset.

3. **Compiled reactivity** (Svelte). The **compiler** analyzes which DOM nodes depend
   on which variables and emits *imperative, surgical update code* at build time. A
   write to a reactive variable marks it dirty and runs the generated update for just
   the affected bindings. **No VDOM, no runtime diff** — the compiler "pre-computes the
   diff." Tiny runtime, fast updates.

4. **Fine-grained signals** (Solid, Angular signals, Vue refs, Preact, Qwik; the TC39
   **Signals** proposal). Components run **once**; reading a signal inside a tracked
   scope **auto-subscribes**; writing a signal notifies **exactly** the computations /
   bindings that read it. **No VDOM, no re-run, no tree diff** — update cost is
   **O(number of changed bindings)**, not O(tree). The runtime is the signal graph
   (subscriber lists + a tracking context + a scheduler).

5. **Server-driven diffs** (Phoenix LiveView, Qwik resumability, islands). State lives
   on the server; a change computes a **diff on the server** and ships **mutation ops**
   over a socket to a thin client that applies them. Directly relevant to **`@state`**
   (remote): the qubepods backend is the "server" and our WebSocket channel is the wire.

## The modern redraw concept (the synthesis)

The 2024–2026 consensus has moved **off the VDOM** toward **fine-grained signals +
compiler assistance**, with one clean separation:

- **"What changed" is tracked at the data layer** — signal reads build a precise
  dependency graph; a write touches only its dependents. (Cost ∝ change, not tree size.)
- **"How to apply it" is a surgical mutation** to a *retained* node tree — `set_attr`
  on the exact node, not a re-rendered subtree.
- **The compiler does as much as possible ahead of time** (Svelte; React Forget; Vue
  Vapor), so the runtime stays tiny.

So: **signals decide *what*, a retained mutation protocol applies *how*, and the
compiler removes runtime bookkeeping wherever dependencies are statically knowable.**
VDOM diffing is the previous generation.

## q64's opportunity

q64 is unusually well-placed, because it is an **AOT compiler with an effect system**
emitting to wasm — exactly the Svelte/Solid-compiler sweet spot. It can do at
*compile time* what JS frameworks do at runtime:

- **Statically derive the dependency graph.** The compiler can see which `state` each
  piece of `draw` reads and emit, per state field, a **mutation function** —
  `on count change → qview.set_attr(numberNode, count)` — skipping both the VDOM and a
  runtime signal graph for the *static* cases. (Svelte-style, but AOT to wasm.)
- **Fall back to runtime signals** only for genuinely dynamic dependencies
  (conditionals, lists, computed keys) — Solid-style — which is the part that needs
  closures + heap aggregates in the IR.
- **The `Renderer` face is the mutation protocol.** `create_node / set_attr /
  mutate(diff) / present` against a **retained** host node tree is host-agnostic — DOM,
  WebGPU, UIKit, Compose all consume the same op stream. q64 emits **mutations, not
  re-rendered trees.**
- **`state` and `@state` converge on one protocol.** Local `state` produces mutations
  *in the wasm*; remote `@state` produces the *same* mutations from the **qubepods
  backend** (LiveView-style) over the WebSocket channel. The client applies one kind of
  diff regardless of origin; the only difference is where it's computed and the `@kv`
  effect that surfaces remote state in the qube manifest.

## Rendering substrate: WebGPU-only (decision)

**QView targets WebGPU; we do not support old browsers or a DOM/canvas2d fallback.**
Baseline is iPadOS 18+ Safari and modern Chrome/Firefox (where WebGPU + wasm32 both
run). If `navigator.gpu` is absent we show a labeled "unsupported" message — we never
fall back to a second renderer. Consequences for this design:

- The retained tree the protocol mutates is a **GPU scene graph**, not a DOM:
  `node_id → draw record` (a quad/glyph-run with transform, color, clip, z). `set_attr`
  edits a draw record; `present` re-encodes **only the changed draws** into the command
  buffer. The "diff" is over GPU draw state, not DOM nodes — but the *decision concept*
  (signals decide what; surgical mutation applies how) is identical.
- **One renderer, everywhere.** WebGPU on the web and `wgpu`/Dawn → Metal/Vulkan/D3D12
  on native (per [`stdlib/gfx`](../stdlib/gfx)) means the same scene graph + mutation
  protocol serve web *and* the future native/JSI targets — no DOM-vs-native split.
- **Text** is a persistent **glyph atlas** (rasterized once, sampled in WebGPU);
  later, GPU-native/SDF glyphs. No DOM text, ever.
- It frees us from DOM reconciliation semantics (keys-as-DOM-identity, hydration);
  node identity is just our `node_id → GPU object` map.

## Recommended model + staged path

Target: **signal-decides-what + retained-mutation-applies-how**, with the **compiler
generating the bindings** where it can. Get there in stages, each shippable:

- **Stage 0 — immediate mode (done).** Full re-emit + full WebGPU repaint. Proves the
  seam; the throwaway-able front.
- **Stage 1 — wasm-owned `state` + host-side diff (small).** Lower `state x = v` to a
  wasm **global** (+ get/set) and export `on_press` to mutate it; give each `qview`
  widget a **stable id**; the host keeps the previous scene and emits only `set_attr`
  for changed fields instead of repainting. → retained node identity + minimal updates,
  with almost no new language features. This is "React semantics without VDOM overhead
  at our scale," and it already exercises the `Renderer`-face shape.
- **Stage 2 — compiled reactivity (Svelte-style; the q64-native win).** A compiler pass
  derives `state → binding` dependencies from `draw` and emits a mutation per state
  field, dropping the re-run-`draw` step for static bindings. Needs: the dependency
  analysis pass + a stable node-id model in codegen + the retained `Renderer` face.
- **Stage 3 — fine-grained signals (Solid-style; later).** Runtime `Signal/Memo/Watch`
  (`stdlib/reactive`) for dynamic dependencies. Gated on the bigger language lift:
  **closures/effects + heap aggregates (records/arrays/ADTs) + an allocator** exposed to
  user code, plus a scheduler.

**Cross-cutting (all stages):** batch writes per event/frame (coalesce to one redraw);
**keyed reconciliation** for lists (identity + minimal moves); a tiny **scheduler**
(run dirty work after the handler returns). Keep reactivity **in the wasm** (the
language owns `state`; the host only applies mutations) so the same model serves the
future native/JSI renderers.

## The mutation protocol (where Stage 1→2 lead)

Grow the `qview` host face from "`present(full scene)`" into the retained `Renderer`
contract, all ops over i64 ids/values (wasm32-clean):

```
qview.create(node_id, kind, parent_id)      // kind: text|number|box|button|…
qview.set_attr(node_id, attr_id, value)     // x|y|w|h|color|label_id|number|enabled…
qview.remove(node_id)
qview.on(node_id, event_id, handler_export)  // wire input → an exported wasm handler
qview.present()                              // commit the frame's mutations
```

The host keeps a `node_id → GPU draw record` map (identity preserved). Stage 1 can emit
`create` once and then only `set_attr` on change; Stage 2 has the compiler emit exactly
those `set_attr`s per state write. Remote `@state` emits the same ops from the backend.

## Open decisions

- **Granularity of Stage 2 dependency analysis** (per-field vs per-node vs per-subtree).
- **List reconciliation key source** (explicit `key:` in the DSL vs positional).
- **Scheduling** (sync after handler vs rAF-batched; priority for `@state` network diffs).
- **`@state` transport** (reuse the gate WebSocket; diff format = the same `mutate` ops).
- **How much stays runtime vs compiled** once closures/aggregates land (Stage 3 scope).
