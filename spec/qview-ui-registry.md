# QView component registry — verified compositions you copy and own

> **Status: design note / draft.** Builds on the QView mutation protocol
> ([`qview-protocol.md`](./qview-protocol.md)), the staged reactivity model
> ([`reactivity.md`](./reactivity.md)), the command-as-agent-surface property
> ([`agent-ui.md`](./agent-ui.md)), and the planned renderer-agnostic view
> vocabulary ([`../stdlib/view/README.md`](../stdlib/view/README.md)). It
> proposes an ecosystem layer, not a language change: a registry of
> hand-verified UI compositions distributed through the Continuum, following the
> "copy the source into your project and own it" component-registry pattern.

## The problem

A QView screen is, at Stage 1, an imperative stream of integer-addressed
mutations. From the widget gallery (`runtime/web-retained/screen.q`):

```q64
qview.create(20, 6, 130)        // node 20, kind 6 (button), parent 130
qview.set_attr(20, 2, 150)      // attr 2 (w) = 150
qview.set_attr(20, 3, 48)       // attr 3 (h) = 48
qview.set_attr(20, 4, 12)       // attr 4 (radius) = 12
qview.set_attr(20, 9, 1011)     // attr 9 (text_id) = glyph 1011
qview.on(20, 0, 20)             // event 0 (press) -> on_20
```

That contract is correct and deliberately minimal — but it is a *backend
target*, not an *authoring surface*. Three frictions fall on whoever writes it
(a human, or — per [`agent-ui.md`](./agent-ui.md) — a coding agent emitting the
same stream):

- **Manual node-id bookkeeping.** Ids (`20`, `130`, …) are hand-allocated and
  must stay unique and stable across every `set_attr`/`on` that touches the node.
- **Untyped integers.** `set_attr(id, 2, 150)` carries no meaning without the
  comment; `2` is `w`, `20` is `surface`, and the two are a typo apart.
- **No shared building blocks.** Every "card", "form field", or "join button" is
  re-derived from primitives in each program, so each app re-invents — and
  re-breaks — the same compositions.

The planned `q64.view` stdlib ([`../stdlib/view/README.md`](../stdlib/view/README.md))
addresses the first two with a typed view vocabulary and a host-implemented
`Renderer` face. This note addresses the **third**: where verified, named,
themeable compositions come from, and how they reach a project.

## The distribution model: copy-and-own, not a runtime dependency

The model this note adopts is a **component registry**: source you install
*into* your project with a CLI, then own and edit, rather than a versioned
runtime dependency you import opaquely. It is a strong fit for QView for reasons
that are sharper here than on the web:

- **The producer must read and edit the component.** A vendored
  `src/ui/card.q` is in-source: a human (or an agent, per `agent-ui.md`) can
  restyle it, add a variant, or fix it. A linked library qube is opaque at the
  call site.
- **No runtime version-lock in a pre-1.0, append-only protocol.** Copied source
  pins to the `PROTOCOL_VERSION` it was generated against (`'1.10'` today); a
  protocol append is a visible, reviewable diff rather than a silent dependency
  bump.
- **Effects stay honest.** A composition that only calls `qview.*` carries
  `@ui` and nothing else (per [`effects.md`](./effects.md) and the manifest
  capability derivation in [`qube.json5.md`](./qube.json5.md)). Because it lives
  in the consumer's own `src/`, there is no transitive capability arriving
  through a dependency.
- **Familiar vocabulary lowers the barrier.** Component names, a `variant`
  parameter, and a `background`/`foreground`/`primary`/`radius` token set are
  already familiar from the web component ecosystem — to humans and to coding
  agents alike, for which q64 is otherwise an unfamiliar target.

## Two layers: `q64.view` (linked) vs. the registry (copied)

The split separates the linked foundation from the copied-in content built on
it:

| Layer | Form | Home |
|---|---|---|
| **`q64.view`** — the `Renderer` face, named protocol constants, an id-allocating context, `Style`/theme tokens, base views (`Container`, `Text`, `Button`, …) | linked stdlib qube | shipped with the toolchain (`q64.*`) |
| **QView component registry** — verified *compositions* and *blocks* (`card`, `field`, a `variant`-driven `button`, a whole `join_form`) | source copied into `src/ui/`, owned by the consumer | the Continuum (+ optional doc mirror) |

`q64.view` is the foundation the unimplemented `stdlib/view` already describes;
the registry is content *on top of it*.

## What a registry component is

A component is a q64 function that **emits the op stream against a small
context**, returns the node id it created, and takes variant parameters. The
context is what removes the id-bookkeeping friction.

> Illustrative q64. [`agent-ui.md`](./agent-ui.md) notes the `screen { … }` view
> DSL is not yet in the language, so the registry ships plain functions over
> `qview.*` plus a `Ctx` from `q64.view`. This is the "lowered" form the typed
> `View`/`Renderer` faces will later formalize; the source is written to survive
> that lift.

Named protocol constants — the q64-side mirror of
`runtime/web-retained/protocol.js`, owned by `q64.view`:

```q64
// q64.view.proto  (mirrors PROTOCOL_VERSION '1.10')
pub const KIND    = { box: 0, row: 1, column: 2, label: 4, button: 6, text_input: 17, /* … */ }
pub const ATTR    = { x: 0, y: 1, w: 2, h: 3, radius: 4, fg: 8, text_id: 9,
                      surface: 20, align: 21, pad: 22, gap: 19 }
pub const SURFACE = { none: 0, surface: 1, material: 2, material_thin: 3, scrim: 4 }
pub const ALIGN   = { start: 0, center: 1, end: 2, stretch: 3 }
pub const EVENT   = { press: 0, change: 1, input: 2 }
```

A component built on them:

```q64
// src/ui/card.q  — vendored; the consumer owns this file
use q64.view.proto.{ KIND, ATTR, SURFACE }

// A frosted container. `c` allocates ids and holds the theme tokens; returns
// the node id so callers can parent children under it.
pub fn card(c: Ctx, parent: i64) -> i64 {
  let id = c.next()                                    // no manual id bookkeeping
  qview.create(id, KIND.box, parent)
  qview.set_attr(id, ATTR.surface, SURFACE.material)   // theme-resolved, not a literal color
  qview.set_attr(id, ATTR.radius,  c.theme.radius)
  qview.set_attr(id, ATTR.pad,     c.theme.space_4)
  return id
}
```

```q64
// src/ui/button.q
use q64.view.proto.{ KIND, ATTR, EVENT }

// `variant` selects a SURFACE/fg token pair — one source file, many looks.
pub fn button(c: Ctx, parent: i64, label: i64, variant: i64, on_press: i64) -> i64 {
  let id = c.next()
  qview.create(id, KIND.button, parent)
  qview.set_attr(id, ATTR.h,       c.theme.control_h)
  qview.set_attr(id, ATTR.radius,  c.theme.radius)
  qview.set_attr(id, ATTR.text_id, label)
  c.theme.apply_variant(id, variant)                   // sets surface + fg from the token set
  qview.on(id, EVENT.press, on_press)
  return id
}
```

The contract, stated:

- **Pure over the `@ui` op stream.** A composition calls only `qview.*`, so it
  contributes `@ui` and no other capability.
- **`Ctx` owns id allocation and a theme handle.** `c.next()` is the monotonic
  id cursor; `c.theme` is the token table (§"Theme tokens").
- **Variants are parameters, not forks.** One `button.q`; `variant` selects a
  token set, rather than a separate file per look.
- **Returns the node id**, so composition is passing `parent` downward, and
  handlers can `set_attr` the node later — the surgical, node-addressed update
  the retained model is built for ([`agent-ui.md`](./agent-ui.md) §"Server-driven,
  per-user, surgical").

## What lands in a project

```
my-app/
  qube.json5
  src/
    main.q
    ui/
      theme.q          # token table (see below)
      card.q           # ← copied by `qube ui add card`
      button.q
      field.q
      ui.lock.json5    # installed components + the PROTOCOL_VERSION they target
```

`ui.lock.json5` is the registry lockfile: it records each vendored component,
the registry source it came from, and the `PROTOCOL_VERSION` (`'1.10'`) it was
generated against — so a protocol append can flag a stale copy rather than break
silently.

## CLI surface — mirror `qube add`

```
qube ui add card button field      # copy components into src/ui/, update ui.lock.json5
qube ui list                       # installed components + protocol drift vs current
qube ui diff card                  # local edits vs the registry source (you own it — this shows drift)
```

This reuses the resolution path of `qube add` (per [`qube-cli.md`](./qube-cli.md)),
with one deliberate divergence: `qube ui add` **writes source into `src/ui/`**
instead of recording a runtime dependency. That divergence is the entire point.

## The registry

Hosted in the Continuum like any qube content — content-addressed `.zip`,
canonical SHA-256 (per [`continuum-api.md`](./continuum-api.md)) — under a
reserved namespace (e.g. `q64.view.registry.*`, snake_case reverse-DNS per the
naming rule in [`qube.json5.md`](./qube.json5.md)). An index records each
component, its files, and its `q64.view` requirements:

```json5
{
  protocol: "1.10",
  components: {
    card:      { files: ["card.q"],                        requires: ["proto", "ctx"] },
    button:    { files: ["button.q"],                      requires: ["proto", "ctx", "theme"] },
    field:     { files: ["field.q", "field_handlers.q"],   requires: ["proto", "ctx", "theme"] },
    // a "block" — a whole composed section, not just a single widget
    join_form: { files: ["join_form.q"],                   requires: ["card", "field", "button"] },
  }
}
```

**Blocks** — whole composed sections rather than single widgets — are where the
registry earns its keep: a verified `join_form` is a drop-in section, not a pile
of primitives a producer must re-assemble correctly each time.

## Theme tokens map onto QView's semantic roles

QView already resolves `ATTR.surface` against a per-platform theme (iOS,
Material 3, desktop — `runtime/web-retained/theme.js`). The registry's token
table names those roles with a familiar vocabulary and lets one `theme.q`
reskin every component:

| Familiar token | QView mechanism |
|---|---|
| `background` / `card` / `popover` | `ATTR.surface` = `SURFACE.surface` / `material` / `scrim` (theme-resolved) |
| `foreground` / `muted-foreground` | `ATTR.fg`, a packed color from the token table |
| `primary` / `secondary` / `destructive` (variants) | `theme.apply_variant(id, …)` → a surface + fg pair |
| `radius` | `theme.radius` → `ATTR.radius` |
| spacing scale (`space_2/4/6`) | `theme.space_*` → `ATTR.pad` / `ATTR.gap` |

Because the underlying role resolution is QView's, the per-platform look (iOS
blue, Material tonal, desktop neutral) comes for free — more than a web token
set delivers.

## Worked example

**Before** — raw ops, the friction this note targets:

```q64
qview.create(300, 0, 100)
qview.set_attr(300, 20, 2)     // surface material — 2 or 3?
qview.set_attr(300, 4, 12)
qview.create(301, 17, 300)     // a field; remember to wire on(301, 2, …)
qview.set_attr(301, 2, 320)
qview.create(302, 6, 300)      // a button
qview.set_attr(302, 9, 1040)
qview.on(302, 0, 302)
// …plus the matching on_302, by hand
```

**After** — composed from the registry:

```q64
use q64.view.{ Ctx }
use ui.{ card, field, button }

fn main {
  let c    = Ctx.new()
  let root = card(c, 0)
  field(c, root, glyph.email_placeholder)
  button(c, root, glyph.join, variant.primary, handler.on_join)
  qview.present()
}
```

The identical op stream reaches the host; the producer reasons in
`card`/`field`/`button` and a `variant`, not integer triples.

## Relationship to the rest

- **[`qview-protocol.md`](./qview-protocol.md)** — the op/enum contract every
  component lowers to; `ui.lock.json5` pins to its `PROTOCOL_VERSION`.
- **[`../stdlib/view/README.md`](../stdlib/view/README.md)** — `q64.view`
  provides the `Ctx`, named constants, `Style`/tokens, and base views the
  registry builds on. The registry is the natural source of the *compositions*
  that README's base views compose into.
- **[`reactivity.md`](./reactivity.md)** — Stage 1 components re-emit changed
  nodes in handlers by hand (the example above); when Stage 2 compiled
  reactivity lands, id allocation becomes compiler-assigned and `Ctx` folds into
  codegen. Registry source is written to survive that lift.
- **[`agent-ui.md`](./agent-ui.md)** — a coding agent is just another producer
  of the same stream; named compositions are as much an agent affordance as a
  human one, and stay inside the same effect/capability sandbox.

## Open questions

- **Id allocation across stages.** `Ctx.next()` is a Stage-1 device; the
  Stage-2 compiler will assign ids. The registry source should remain valid as
  the lowered form, but the migration path needs specifying.
- **Behavior beyond drawing.** Web component kits inherit focus-trap, keyboard
  nav, and ARIA from unstyled primitives. QView widgets are host-drawn
  (`runtime/web-retained/widgets.js`), so that behavior lives in the host, not
  the component. Accessibility is a host concern here; the registry must not
  pretend otherwise.
- **Namespace and ownership.** Whether the registry is a reserved `q64.view.*`
  sub-namespace, a separate Continuum category, or both — and the review bar for
  a composition to be called "verified".
- **Doc mirror.** Whether components are also published as fetchable
  source/markdown at stable URLs (the docs-as-distribution pattern), in addition
  to Continuum archives.
