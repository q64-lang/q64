# stdlib/layout → `q64.layout`

Declarative layout vocabulary. Defines the *shape* of layout; ships no solver.

> **Status: not yet implemented.**

## Surface (planned)

- **Geometry** — `Rect`, `Size`, `Point`, `Edge`, `Axis`, `Anchor`.
- **`Constraint`** kinds — `Equality`, `Inequality`, `LinearCombination`,
  `AspectRatio`, `ContentDriven`, each carrying a `Strength`.
- **`IntrinsicSize`** trait — anything that can describe its natural size to
  a solver (`measure(available: Size) -> Size`).
- **`LayoutTree<N>`** — a tree of nodes, each holding a constraint set, with
  a pluggable solver via the `Solver` trait.
- **`Diagnostics`** — per-dimension attribution records and a
  dropped-constraint log so unsatisfiable inputs degrade rather than crash.

No solver implementation lives here. Concrete solvers (Cassowary, Yoga, …)
are separate qubes that implement `Solver`; user code stays portable across
them. Renderer-agnostic by construction: a `LayoutTree<N>` solves without
knowing how `N` is drawn.
