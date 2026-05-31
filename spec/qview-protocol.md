# QView mutation protocol — the retained Renderer contract (Stage 1)

> **Status: draft (v0) — proposed.** Specifies the **retained, node-addressed
> op set** that a QView producer (the q64 compiler today; an agent tomorrow)
> emits and a host renderer applies. This is the **Stage 1** surface from
> [`reactivity.md`](./reactivity.md) §"Recommended model + staged path": grow
> the immediate-mode `qview` POC face (`text`/`number`/`button`/`present`) into
> the retained `create_node`/`set_attr`/`remove`/`on`/`present` contract with
> **stable node ids** and **host-side diffing**. It is the versioned contract
> [`agent-ui.md`](./agent-ui.md) requires, and the `Renderer` face
> [`stdlib/view`](../stdlib/view) is written against. Pairs with
> [`env.md`](./env.md) (the `@ui` effect) and [`effects.md`](./effects.md).

## Why this exists

A UI is `view = f(state)`. The POC re-emits the whole scene and repaints every
frame (immediate mode): zero bookkeeping, but it loses **node identity** (focus,
caret, scroll, in-flight animation) and repaints unrelated UI. Stage 1 fixes
both by making the scene a **retained tree of addressable nodes** and shipping
**mutations**, not re-rendered trees:

- **Producer** (wasm or agent) assigns every widget a **stable `node_id`** and
  emits only the ops that change between frames.
- **Host** keeps a `node_id → draw record` map (the retained scene) and applies
  `set_attr` to the exact node — no blind repaint, identity preserved.

The same op set serves **local `state`** (mutations originate in the wasm) and
**remote `@state`** (the qubepods twin emits the same ops over the gate socket);
the host applies one kind of diff regardless of origin (see
[`reactivity.md`](./reactivity.md) §`state` vs `@state`).

This document fixes **one renderer-agnostic contract**. The self-drawn WebGPU/SDF
host (the decided substrate — [`reactivity.md`](./reactivity.md) §"Rendering
substrate") is its first consumer; a future native/JSI host
([`runtime/jsi`](../runtime/jsi)) consumes the *same* ops. Producers never know
which renderer applies them.

## The op set

Five ops. All arguments are **`i64`** (wasm32-clean: ids, enum tags, and packed
values all fit i64; no pointers cross the boundary). The host declares each as a
wasm import under the `qview` module.

```
qview.create(node_id: i64, kind: i64, parent_id: i64)
qview.set_attr(node_id: i64, attr: i64, value: i64)
qview.remove(node_id: i64)
qview.on(node_id: i64, event: i64, handler: i64)
qview.present()
```

| Op | Meaning |
|---|---|
| `create(id, kind, parent)` | Create a node of `kind` as a child of `parent` (`parent = 0` ⇒ the root). `id` must be previously unused (per frame epoch). Idempotent re-create with the same `(id, kind, parent)` is a no-op; a conflicting kind is a protocol error. |
| `set_attr(id, attr, value)` | Set attribute `attr` on node `id` to `value` (encoding per [§Attributes](#attributes)). Setting an attr a node's kind doesn't define is a protocol error. |
| `remove(id)` | Remove node `id` **and its subtree**. Removing an unknown id is a no-op. |
| `on(id, event, handler)` | Wire input `event` on node `id` to an exported wasm handler. `handler` is a **handler id** (see [§Events](#events)); `handler = 0` unbinds. |
| `present()` | Commit the frame: the host applies the accumulated mutations and re-encodes **only changed draws**. One redraw per `present`, regardless of mutation count. |

**Frame model.** A producer emits a batch of ops terminated by `present()`. The
host buffers ops since the last `present` and applies them atomically — partial
frames are never displayed. Between frames the retained tree persists; a steady
UI emits **zero** ops until state changes.

**Ordering.** Within a frame: `create` before any `set_attr`/`on` referencing
that id; a parent's `create` before its children's. `remove` of a parent
implicitly removes descendants, so explicit child `remove`s are optional. The
host applies ops in emission order.

## Node ids

- `node_id` is a **producer-assigned, stable `i64`**, unique within a screen
  instance and **persistent across frames** — the same widget keeps the same id
  for its lifetime. Stability is what preserves identity (focus/caret/scroll) and
  makes `set_attr` surgical.
- `0` is reserved for the **implicit root** node (the screen surface); producers
  never `create` or `remove` it.
- The Stage 1 compiler assigns ids by **lexical position** of each widget in the
  `draw` block (deterministic, stable across recompiles of unchanged source).
  Lists/conditionals get **keyed** ids in Stage 2+ (see [§Open](#open-questions)).

## Node kinds

Closed, versioned enum. The Stage-1 set covers the first widget batch (the
gallery). Kinds are **layout/containers**, **leaves**, or **controls**; the host
maps each to an SDF draw + hit region. Unknown kinds are a protocol error.

| `kind` | Name | Category | Notes |
|---|---|---|---|
| `0` | `box` | container | rounded-rect SDF; the base surface every control composes from |
| `1` | `row` | layout | main-axis = x; lays children left→right |
| `2` | `column` | layout | main-axis = y; lays children top→bottom |
| `3` | `stack` | layout | z-stacked; children share the parent's rect |
| `4` | `label` | leaf | text by `text_id` (host glyph catalog in Stage 1; see [§Text](#text-in-stage-1)) |
| `5` | `image` | leaf | textured quad by `image_id` |
| `6` | `button` | control | `box` + centered `label`; emits `press` |
| `7` | `checkbox` | control | boolean; `checked` attr; emits `change` |
| `8` | `switch` | control | boolean toggle; `checked` attr; emits `change` |
| `9` | `radio` | control | one-of-group; `group` + `selected` attrs; emits `change` |
| `10` | `slider` | control | ranged; `min`/`max`/`value` attrs; emits `input` (drag) + `change` (commit) |
| `11` | `progress` | leaf | determinate (`value` in `min`/`max`) or indeterminate (`value = -1`) |
| `12` | `dropdown` | control | select-one; `selected` attr indexes a host-held option set; emits `change` |

> **Text input is deferred** (caret/focus/IME is a larger lift) and will be added
> as kind `13` `text_input` in a focused follow-up, with `focus`/`blur`/`key`
> events and a `caret` attr. The op set and enums here are forward-compatible:
> adding a kind/attr/event bumps the protocol minor version, never breaks it.

## Attributes

Closed, versioned enum. Each attr applies to a stated set of kinds; an attr on a
kind that doesn't define it is a protocol error. **Geometry** attrs apply to every
node; the rest are kind-specific. Values are `i64`, encoded per the **Value
encoding** column.

| `attr` | Name | Applies to | Value encoding |
|---|---|---|---|
| `0` | `x` | all | device-independent px, signed |
| `1` | `y` | all | px, signed |
| `2` | `w` | all | px, ≥ 0 |
| `3` | `h` | all | px, ≥ 0 |
| `4` | `radius` | box, button, controls | corner radius px |
| `5` | `border_w` | box, button, controls | border width px |
| `6` | `fill` | box, button, controls, progress | packed `0xAARRGGBB` |
| `7` | `border` | box, button, controls | packed `0xAARRGGBB` |
| `8` | `fg` | label, controls | packed `0xAARRGGBB` (text/foreground) |
| `9` | `text_id` | label, button | host glyph-catalog id (Stage 1) |
| `10` | `image_id` | image | host image id |
| `11` | `enabled` | controls | `0` = disabled, `1` = enabled |
| `12` | `checked` | checkbox, switch | `0` / `1` |
| `13` | `selected` | radio, dropdown | selected index (`-1` = none) |
| `14` | `group` | radio | group id (radios sharing it are exclusive) |
| `15` | `min` | slider, progress | ranged-value floor |
| `16` | `max` | slider, progress | ranged-value ceiling |
| `17` | `value` | slider, progress | current value (clamped to `[min,max]`; `-1` = indeterminate for progress) |
| `18` | `z` | all | stacking order within parent (default = creation order) |
| `19` | `gap` | row, column | inter-child spacing px |

**Color** is a packed `i64` `0x00000000AARRGGBB` (high 32 bits zero). **Geometry**
is integer px in a device-independent coordinate space; the host scales by DPR
(matching the POC's `DPR` handling in `runtime/web/app.js`). Stage 1 keeps values
scalar; transforms/clip arrive with the floating-layers work (Stage 2+).

## Events

Closed, versioned enum. `qview.on(node_id, event, handler)` binds an input on a
node to an exported wasm handler.

| `event` | Name | Fired by | Delivered when |
|---|---|---|---|
| `0` | `press` | button | pointer down+up inside the node |
| `1` | `change` | checkbox, switch, radio, slider, dropdown | committed value change |
| `2` | `input` | slider | continuous value change during drag |
| `3` | `drag` | any | pointer drag over the node |
| `4` | `key` | (reserved for `text_input`) | key event while focused |
| `5` | `focus` | (reserved for `text_input`) | node gains focus |
| `6` | `blur` | (reserved for `text_input`) | node loses focus |

**Handler binding.** `handler` is a **handler id** the producer assigns; the host
calls back into the wasm by invoking the matching **exported function** named by
convention `on_<handler_id>` (e.g. handler `20` ⇒ export `on_20`), passing
`(node_id, event)` as `i64` args so a shared handler can still tell what fired.
This keeps the callback path integer-only and avoids funcrefs crossing the
boundary in Stage 1. The handler reads/writes `state`, mutates the changed
nodes via `set_attr`, and calls `present()`. A host MAY fall back to a single
`on_event(node_id, event)` dispatcher when no `on_<handler_id>` export exists —
both shapes are supported; the per-handler form is what the q64 compiler emits
cleanly today (one branchless function per wired control, no in-handler
branching). This is the shape the gallery (`runtime/web-retained`) uses.

**Event payloads.** Stage 1 handlers receive `(node_id, event)` but carry no
value payload (state lives in wasm globals; the host knows which node fired).
Carrying a value (e.g. the new slider position, a key code) is an
[open question](#open-questions); the likely shape is a host-set wasm global the
handler reads, keeping the arg list fixed.

## Text in Stage 1

Stage 1 keeps the POC's **host-owned glyph catalog**: a `label`/`button` carries a
`text_id` (attr `9`) into a host string table; no strings cross the wasm boundary.
This is a deliberate scaffold — it unblocks every widget that *shows* a fixed
label without first solving the string ABI. **Producer-owned strings** (a wasm32
`(ptr,len)` read by the host, per the wasm32 string-ABI work) land alongside
`text_input`, since both need it. Until then, dynamic text uses `number` semantics
(the host renders an integer) as the POC does.

## The `@ui` effect

Any `qview.*` op is a host-capability call, so it carries the **`@ui`** effect
(`effects.zig` maps the `qview` face → `.ui`; see
[`reactivity.md`](./reactivity.md) and [`env.md`](./env.md)). `@ui` propagates
through the call graph into the qube's capability set → the manifest `imports` →
QAD/AI-visibility, exactly like any other capability. A pure (non-drawing) qube
never gains `@ui`.

## Versioning

The op set and the three enums (`kind`, `attr`, `event`) are a **versioned
contract** ([`agent-ui.md`](./agent-ui.md)). The version is a single integer the
host and producer agree on at handshake (Stage 1: a constant the host pins;
later: negotiated). **Adding** a kind/attr/event or a new op is a **minor** bump
(backward-compatible — old producers keep working). **Changing the meaning or
encoding** of an existing tag is a **major** bump. Enum tags are **append-only**;
retired tags are tombstoned, never reused.

## Host obligations (per [`agent-ui.md`](./agent-ui.md) §"Safe by construction")

A host applying an op stream — especially an **agent**-produced one — MUST:

1. **Schema-validate** every op: well-formed args, known `kind`/`attr`/`event`
   tags, valid node refs, attr-applies-to-kind. Reject malformed/dangling
   mutations (a producer error is a dropped op + diagnostic, never a crash).
2. **Authority-check** capability invocations against the qube's granted set
   (draw ops are always allowed; capability calls are not forgeable).
3. Apply the usual operational guards (rate/quota on agent-driven mutations;
   treat agent-supplied text/content as untrusted — escape on render).

## What Stage 1 deliberately does **not** include

- **Compiler-derived bindings** (which `state` writes touch which node attrs) —
  that's Stage 2 (compiled reactivity). Stage 1's producer re-emits changed nodes
  by hand in handlers; the *host* does the diffing.
- **Runtime signals** (`Signal`/`Memo`/`Watch`) — Stage 3.
- **Keyed list reconciliation** — Stage 1 ids are lexical; lists come with keys.
- **Transforms / clip / floating layers**, **MSDF text**, **producer-owned
  strings**, **`text_input`** — all forward-compatible follow-ups.

## Open questions

- **Event payloads** — host-set wasm global vs widening the handler ABI to carry
  args (slider value, key code, drag delta).
- **Handler naming** — *(resolved for Stage 1)* the host tries `on_<id>` first,
  then falls back to a single `on_event(node_id, event)` dispatcher. The
  per-handler form wins because the compiler emits branchless `on_<id>` functions
  today (in-handler `if` branching on `node_id` is a later compiler lift).
- **Node-id allocation for lists/conditionals** — explicit `key:` in the `draw`
  DSL vs positional; the source of stable ids under dynamic children.
- **Coordinate space** — keep integer px (Stage 1) vs fixed-point sub-pixel for
  animation; when transforms land.
- **`present` batching** — sync after handler return vs rAF-coalesced; priority
  for remote `@state` diffs vs local input.
