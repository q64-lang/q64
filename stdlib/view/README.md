# stdlib/view → `q64.view`

Renderer-agnostic view tree. The vocabulary every UI consumer composes;
actual drawing is the host's job.

> **Status: not yet implemented.**

## Surface (planned)

- **`View`** trait — `render(into: Surface)`, parameterized over a renderer
  face.
- **Built-in views** — `Container`, `Text`, `Image`, `Scroll`, `Stack`,
  `Grid`, `Input`, `Button`, each generic over its child type.
- **`Style`** — typography, color, spacing, border, shadow as typed values
  (not strings). Composes; does not inherit CSS semantics.
- **`Renderer`** face — the host-implemented contract: `create_node`,
  `set_attr`, `mutate(diff)`, `present`.

Built on top of [`q64.layout`](../layout): every `View` carries a constraint
set. Input is delivered through [`q64.event`](../event); state-driven
updates ride [`q64.reactive`](../reactive). The view tree itself never
touches a screen — it is consumed by a `Renderer` running in the host
(browser DOM, native shell, terminal, headless test surface).

Verified *compositions* on top of these base views (a themeable `card`,
`button`, `field`, or a whole `join_form` block) are distributed separately as
a copy-and-own registry — see
[`spec/qview-ui-registry.md`](../../spec/qview-ui-registry.md).
