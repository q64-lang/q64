# sema — name resolution + type checking (the semantic pass)

The layer between `parser/` and `ir/`. Rung **A0** of the semantic-pass
ladder in [`todo.md`](../../../todo.md) §"Semantic pass + struct values →
static fits": this package records the placement decision and lands the
scaffold (the file-level symbol table + `q64 show symbols`); the rungs
A1–A4 grow it into the real pass.

## Placement (the A0 decision)

```
parse (CST/AST)
  → sema        ← THIS PACKAGE: symbol table, import bindings,
  |               (A2+) interned types, (A4) TYP diagnostics
  → build_hir   consumes sema's results; ad-hoc typing retired at A3
  → lower (MIR)
  → backend (Binaryen)
```

- **`sema` imports `parser` only.** Never `ir/`, never Binaryen — same
  backend-neutrality rule as `ir/`. `ir/build_hir` will import `sema`
  (one-directional; sema stays HIR-free).
- **Additive until A3.** Today `build_hir` types on the scalar floor and
  `codegen/emit.zig`'s `Resolver` owns import resolution. Sema lands
  *alongside* them; at A3 `build_hir` switches to consuming sema's
  resolved symbols/types and the `Resolver` shrinks to module-source
  loading. Until then, nothing in the emit path changes.
- **Lifetimes.** A `SymbolTable` owns its strings (names, origins) and
  is independent of the parse result; AST handles are deliberately not
  retained (the A1 resolver will re-walk with the parse result alive,
  the way `Resolver.lookup` does today).

## What exists now (A0 scaffold + the A1 slice)

- `symbols.zig` — the file-level `SymbolTable`: one symbol per top-level
  item + per import binding (selective names, `as` aliases, namespace
  imports binding the last path segment), first-binding-wins `lookup`,
  collisions recorded with offsets.
  `fit` declarations are listed but **not** name bindings: a `fit` is
  registered per *(type, face)* pair, so binding its leading type name
  would false-collide with the type's own declaration. The A1 fit
  registry replaces the placeholder entries.
- `fileDiagnostics` — **NAM005** for a collision involving at least one
  import binding (spec/modules.md), located at the second binding.
  Wired into `q64 check` (parse + this pass); covered by the
  `modules/import-collision.q` conformance fixture.
  Declaration-vs-declaration duplicates have no specced code yet and
  stay recorded-only.
- `resolve.zig` — body-level resolution: a lexical scope stack (params,
  `let`/`var` after their initializers, block nesting, `for`/`match`/
  `if let` pattern bindings) classifying every path-expression head.
  Unresolved heads are **recorded, not emitted** — `build_hir` still
  owns rejection (`NameNotFound`) until A3 makes sema the single source
  of truth; emitting NAM010 here would double-diagnose.
  v0 boundaries: interpolation references (`"{name}"`) live in raw
  string tokens (invisible until interpolation is parsed); `screen`
  bodies skipped until the screen lowering lands.
- `q64 show symbols <file.q>` — dumps the table, collisions, and
  unresolved heads (spec/q64-cli.md §"`q64 show` kinds").
  Compiler-introspection; unstable format, like `show hir`.

## Not here yet (by rung)

- **A1 (remaining)** — resolution of import bindings against `--module`
  sources (NAM001/NAM006 at the sema layer), `PAR040` re-land on name
  kinds, the fit registry.
- **A2 (remaining)** — structured `fn` types (blocked on the parser's
  raw fn/dyn/union spans) and struct field shapes (lands with ladder
  B2). The core type store is in (`types.zig`): interned builtin tower,
  named/optional/ref/slice/array/tuple lowering against the symbol
  table, fn-signature collection, unresolved-type recording.
- **A3 (structurally done)** — `ir/build_hir` consumes sema for all
  three: annotations lower through `types.lower` (the `typeNamed`
  text-matching family is gone), expression types come from
  `exprtype.scalarOf` (the `isBoolOp`/`isBoolCall` rules moved here),
  and name lookup is `link.zig`'s `Linker` (the codegen `Resolver`
  moved wholesale; emit.zig maps the UnknownModule/NameNotFound/
  UnsupportedImport trio onto its stable codes at one call site).
  Still in build_hir: body-scope ownership — the `Env` bridge adapts
  its wasm-slot `Scope`. That collapses when the A4 check pass brings
  sema its own body scopes.
- **A4 (in progress)** — `check.zig` is the first emitting layer:
  body walks with sema-owned typed scopes. Shipping in `q64 check`:
  TYP051 (integer condition / integer where bool expected), TYP042
  (mixed numeric arithmetic), TYP041 (numeric mismatch at a declared
  type — call args + annotated lets), TYP050 (bool as integer),
  TYP040 (annotated literal out of range), TYP060 (mode keyword in a
  call argument), TYP061 (wrong argument count — specced this rung;
  positional claims are gated on an argument-list well-formedness
  check, because parse recovery degrades unsupported forms into extra
  CALL_ARGs). `prelude.zig` mirrors modules.md §"The auto-prelude"
  for resolve + type lowering. Conformance 18/48. Still deferred with
  reasons in todo.md: NAM010 + unresolved type names (parser gaps:
  lambdas, graph/channel exprs, named args, record patterns,
  generic-param scoping).
