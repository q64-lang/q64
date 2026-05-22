# annotations

The `@`-form catalog. q64 reuses the `@<ident>` lexical class for
several distinct purposes — markers on declarations, derive
directives, property wrappers, suppression hints, effect markers
on function signatures. This file is the central map: what
exists, where it goes, what it does, and which spec owns the
detailed semantics.

> **Status: draft (v0).** The blessed annotation set below is
> the contract surface — toolchain components may rely on these
> identifiers being reserved. User-defined annotations land
> through PascalCase property wrappers and `@derive`-extensible
> functions; the lowercase namespace is closed for v0.

## Design goals

- **One catalog, many owners.** Every `@`-form belongs to a
  topic spec (`effects.md`, `streams.md`, `memory.md`,
  `faces.md`, `units.md`, `diagnostics.md`, `errors.md`, the
  `test-framework.md`). This file lists them so a
  reader who finds `@stage` in a code snippet has one place to
  look up "what is this and where is it spec'd."
- **Casing is meaning.** Lowercase names are compiler-known and
  reserved; PascalCase names are user-extensible property
  wrappers. The convention disambiguates at a glance and the
  compiler enforces it.
- **Positional disambiguation against effect markers.** The
  same `@IDENT` token names an annotation when it precedes an
  item and an effect marker when it follows a return type. The
  two namespaces are separate; a name may legally exist in only
  one of them at a time, and the compiler refuses overlaps.
- **No silent introduction.** A new lowercase marker requires a
  language-spec change. User code that writes a lowercase `@foo`
  not in this catalog gets `ANN001` (unknown annotation), never
  silent acceptance.

## Vocabulary

| Word                   | Meaning                                                                                                  |
|------------------------|----------------------------------------------------------------------------------------------------------|
| **annotation**         | An `@<ident>` token preceding a declaration. The four categories below.                                  |
| **marker**             | An annotation whose only effect is to flag the item for the compiler or for human readers.               |
| **derive form**        | `@derive(...)` and `@no_derive(...)` — comptime code generation, user-extensible.                        |
| **property wrapper**   | A PascalCase annotation on a field that elaborates the declaration. User-defined; transformed at comptime. |
| **declaration marker** | An annotation that introduces a new nominal type (`@unit`, `@kind`) rather than annotating an existing one. |
| **effect marker**      | An `@<ident>` token appearing after a return type or in an effect bound. Same lexical class, different namespace. See [`effects.md`](./effects.md). |

## The two surfaces sharing `@IDENT`

`@<ident>` is one lexical class with two semantic surfaces:

1. **Annotations** — attached to a declaration *before* the
   item keyword. Resolved against the table in §"The blessed
   annotation surface" below.
2. **Effect markers** — attached *after* a function's return
   type, or as an `@e` substitution in a face bound. Resolved
   against the table in [`effects.md` §"The core effect set"](./effects.md).

The grammar in [`grammar.md` §Annotations](./grammar.md) makes
the position rule precise. The two namespaces are disjoint by
the casing rule below: lowercase identifiers may inhabit at
most one (the language pre-binds names to their category), and
PascalCase identifiers are property wrappers only.

## Casing convention

The load-bearing rule:

| Casing                | Category                                       | Who introduces it           |
|-----------------------|------------------------------------------------|-----------------------------|
| lowercase             | compiler-known marker, derive form, or effect marker | The language (closed set)   |
| PascalCase            | property wrapper                               | User code (open; comptime)  |
| `derive` / `no_derive`| derive forms — call style with arguments       | The language; arguments user-extensible |

A lowercase `@foo` that is not in the blessed catalog is
`ANN001`. A PascalCase `@Foo` that is not bound to a property
wrapper at the use site is `ANN002`. Mixed casing (`@MyStage`,
`@auto_Promote`) is `ANN010` regardless of intent — the casing
rule is mechanical.

`ANN010` is the same casing rule that `EFF141` enforces for
user-defined effects. The duplication exists so that an
annotation-position diagnostic and an effect-position
diagnostic both have a stable code; the messages are
coordinated.

## Annotation categories

Four categories. Every blessed `@`-form belongs to exactly one.

### Category 1 — Compiler-known markers (lowercase)

Built-in. Each marker is hard-coded into the compiler:
type-checker rules, codegen behavior, visibility, or capability
analysis. Not user-extensible.

| Marker            | Position                  | Effect                                                                | Owning spec                          |
|-------------------|---------------------------|-----------------------------------------------------------------------|--------------------------------------|
| `@stage`          | `fn`                      | Marks a function as a stream-graph node.                              | [`streams.md`](./streams.md)         |
| `@fuse`           | `fn` (with `@stage`)      | Hints fusion across an adjacent `@stage` boundary.                    | [`streams.md`](./streams.md)         |
| `@shared`         | `struct`                  | Allocates the struct in `mem.shared`; cross-thread visible.           | [`memory.md`](./memory.md)           |
| `@managed`        | `struct`                  | Allocates the struct in WasmGC memory.                                | [`memory.md`](./memory.md)           |
| `@test`           | `fn`                      | Registers the function with the test runner.                          | [`test-framework.md`](./test-framework.md)    |
| `@skip_laws`      | `fit`                     | Suppresses the face-law check for this fit. Audit-trail required.     | [`faces.md`](./faces.md)             |
| `@traced_panic`   | `fn`                      | Captures a stack trace into the panic payload (opt-in; ~few kB cost). | [`errors.md`](./errors.md)           |
| `@rate`           | `graph` block             | Pins the graph body's ambient stream rate.                            | [`streams.md`](./streams.md)         |

### Category 2 — Declaration markers (lowercase, type-introducing)

A small distinguished subset of category 1 whose syntactic
position is "item-introducing": they declare a new nominal type
rather than annotating an existing item. They share the
annotation form for declaration economy.

| Marker     | Shape                          | Introduces                              | Owning spec                  |
|------------|--------------------------------|-----------------------------------------|------------------------------|
| `@unit`    | `@unit Name : BaseUnit`        | A nominal unit type backed by `BaseUnit`. | [`units.md`](./units.md)     |
| `@kind`    | `@kind Name[…]`                | A zero-cost semantic newtype.            | (forthcoming `kinds.md`)     |

Declaration markers may not be combined with category-1 markers
on the same line — `@shared @kind Foo` is `ANN040`. They produce
items, not annotated items.

### Category 3 — Derive forms

Comptime code generation. The call shape (`@derive(...)`,
`@no_derive(...)`) is the differentiator: arguments are face
names that drive the per-face derivation logic. Faces may opt
into being derivable by exposing a comptime `derive` hook;
beyond that, the form is user-extensible without a language-
spec change.

| Form                | Position            | Owning spec                  |
|---------------------|---------------------|------------------------------|
| `@derive(Face, …)`  | `struct` / `enum`   | [`faces.md`](./faces.md)     |
| `@no_derive(Face, …)` | `struct` / `enum` | [`faces.md`](./faces.md)     |
| `@no_derive(*)`     | `struct` / `enum`   | [`faces.md`](./faces.md)     |

The argument list for `@derive` is comma-separated face
references; `@no_derive` takes the same shape plus the wildcard
`*` form. The grammar lives in
[`grammar.md` §Annotations](./grammar.md); the per-face
semantics live in [`faces.md`](./faces.md).

### Category 4 — Property wrappers (PascalCase)

User-extensible. A property wrapper transforms a field
declaration into an elaborated form at comptime: storage,
accessors, change notifications, atomicity guards. Wrappers are
declared with comptime code in stdlib or user qubes; the
language does not enumerate them.

Stdlib ships an opening set:

| Wrapper        | Wraps                | What it elaborates                                                                | Owning spec                            |
|----------------|----------------------|-----------------------------------------------------------------------------------|----------------------------------------|
| `@Signal`      | field of `T`         | Field becomes a `Signal<T, R>` with publish-on-write and subscriber tracking.     | [`streams.md`](./streams.md)           |
| `@Event`       | field of `T`         | Field becomes an `Event<T>` source.                                               | [`streams.md`](./streams.md)           |
| `@Stream`      | field of `T`         | Field becomes a `Stream<T, R>` source.                                            | [`streams.md`](./streams.md)           |
| `@Atomic`      | field of a scalar    | Field becomes an `Atomic<T>` with the cross-thread access discipline.             | [`memory.md`](./memory.md)             |
| `@Lazy`        | field of `T`         | Field becomes a `Lazy<T>`; initializer runs at first read.                        | (forthcoming `stdlib`)                 |
| `@TaskLocal`   | field of `T`         | Field becomes a task-local handle; reads look up the current task's slot.         | [`concurrency.md`](./concurrency.md)   |
| `@Environment` | field of an `env` face | Field reads from the ambient `env`. Used by the runtime to surface `env` itself; user code uses the ambient form (`env.X`) directly. | [`env.md`](./env.md) |

A user qube introduces a property wrapper with a comptime
declaration; the registration mechanism is spec'd in the
forthcoming `comptime.md`. Wrappers may take arguments
(`@Signal(rate = 60.Hz)` is `IDENT "=" Expr` per the grammar);
the resolution to a comptime function is by name.

## The blessed annotation surface (consolidated table)

The grammar's annotation table in
[`grammar.md` §Annotations](./grammar.md) covers the structural
positions. This is the same table with the category column
filled in.

| Annotation        | Category  | Position                | Owning spec                          |
|-------------------|-----------|-------------------------|--------------------------------------|
| `@stage`          | 1         | `fn`                    | [`streams.md`](./streams.md)         |
| `@fuse`           | 1         | `fn` (with `@stage`)    | [`streams.md`](./streams.md)         |
| `@rate`           | 1         | `graph` block           | [`streams.md`](./streams.md)         |
| `@shared`         | 1         | `struct`                | [`memory.md`](./memory.md)           |
| `@managed`        | 1         | `struct`                | [`memory.md`](./memory.md)           |
| `@test`           | 1         | `fn`                    | [`test-framework.md`](./test-framework.md)    |
| `@skip_laws`      | 1         | `fit`                   | [`faces.md`](./faces.md)             |
| `@traced_panic`   | 1         | `fn`                    | [`errors.md`](./errors.md)           |
| `@unit`           | 2         | item-introducing        | [`units.md`](./units.md)             |
| `@kind`           | 2         | item-introducing        | (forthcoming `kinds.md`)             |
| `@derive(...)`    | 3         | `struct` / `enum`       | [`faces.md`](./faces.md)             |
| `@no_derive(...)` | 3         | `struct` / `enum`       | [`faces.md`](./faces.md)             |
| `@allow(<code>)`  | utility   | any item or stmt        | [`diagnostics.md`](./diagnostics.md) |
| `@Signal`         | 4         | `struct` field          | [`streams.md`](./streams.md)         |
| `@Event`          | 4         | `struct` field          | [`streams.md`](./streams.md)         |
| `@Stream`         | 4         | `struct` field          | [`streams.md`](./streams.md)         |
| `@Atomic`         | 4         | `struct` field          | [`memory.md`](./memory.md)           |
| `@Lazy`           | 4         | `struct` field          | (forthcoming `stdlib`)               |
| `@TaskLocal`      | 4         | `struct` field          | [`concurrency.md`](./concurrency.md) |
| `@Environment`    | 4         | `struct` field (runtime-internal) | [`env.md`](./env.md)        |

`@allow` is the one outlier — it is neither a marker that
participates in type/effect checking, nor a derive form, nor a
wrapper. It is a diagnostic-suppression utility, spec'd in
[`diagnostics.md` §"Suppressing a diagnostic"](./diagnostics.md).
It is listed here for completeness but treated as a separate
utility category.

## Position rules

Annotations bind to the immediately following item. The valid
positions per item kind:

| Item kind     | Annotations admitted                                                          |
|---------------|-------------------------------------------------------------------------------|
| `fn`          | `@stage`, `@fuse`, `@test`, `@traced_panic`, `@allow`, any user-defined effect's decorator. |
| `struct`      | `@shared`, `@managed`, `@derive`, `@no_derive`, `@allow`. Fields may carry property wrappers. |
| `enum`        | `@derive`, `@no_derive`, `@allow`.                                            |
| `fit`         | `@skip_laws`, `@allow`.                                                       |
| `face`        | `@allow`. (Future: `@object_safe` per faces.md is open.)                      |
| `field`       | property wrappers (category 4) and `@allow`. Effect markers do not apply.     |
| `let` / `var` | `@allow` only.                                                                |
| `graph { }`   | `@rate`, `@allow`.                                                            |

A misplacement (e.g., `@stage` on a struct) is `ANN020`. The
diagnostic mentions both the offending annotation and the item
kind so the suggested repair is mechanical.

## Argument forms

Per [`grammar.md` §Annotations](./grammar.md):

```
Annotation     := "@" IDENT ("(" AnnotationArgs? ")")?
AnnotationArgs := AnnotationArg ("," AnnotationArg)* ","?
AnnotationArg  := Expr                                  (* @derive(Eq, Hash) *)
                | IDENT "=" Expr                        (* @Signal(rate = 60.Hz) *)
                | "*"                                   (* @no_derive(*) *)
```

Rules:

- **Bare** (`@stage`) — no parens. Used by markers that take no
  configuration.
- **Positional** (`@derive(Eq, Hash)`) — face references; order
  is informational only (`@derive(Hash, Eq)` is equivalent).
- **Named** (`@Signal(rate = 60.Hz)`) — keyword-arg style for
  property wrappers and configurable markers. The keyword name
  is resolved against the wrapper's parameter list at comptime.
- **Wildcard** (`@no_derive(*)`) — admitted only where the
  owning spec defines it. Currently only `@no_derive`.

A bare-only marker that is invoked with arguments is `ANN030`.
A marker that requires arguments invoked bare is `ANN031`.

## Multiple annotations on one item

An item may carry multiple annotations. Order does not affect
semantics; the compiler resolves them as a set.

```q64
@allow(STR040)
@stage
@fuse
fn lowpass(input: Signal<f32, 48.kHz>) -> Signal<f32, 48.kHz> { … }
```

Duplicates of the same annotation on one item (`@stage @stage
fn …`) are `ANN032`. Annotations that conflict semantically
(`@managed @shared struct …`) are owned by the topic spec —
`REG010` for the `@managed`/`@shared` clash per
[`memory.md`](./memory.md), not by this spec.

Category-2 (declaration) markers do not stack with other
annotations on the same line. `@allow @kind Foo` is `ANN040`;
move the `@allow` to the kind's declaration site if the
suppression is needed.

## Resolution

Annotation name resolution proceeds in this order:

1. **Casing check.** A name violating the casing rule is
   `ANN010` immediately; no further lookup.
2. **Blessed catalog.** A lowercase name is matched against the
   catalog above. A hit pins category and owning spec.
3. **Property-wrapper resolution.** A PascalCase name is
   resolved against in-scope wrapper declarations at comptime.
   Stdlib wrappers are in the auto-prelude; user wrappers are
   imported per [`modules.md`](./modules.md).
4. **Unknown.** A name that survives steps 1-3 is `ANN001`
   (lowercase) or `ANN002` (PascalCase). The diagnostic
   suggests near-spellings from the blessed catalog.

## Annotations vs. effect markers — disambiguation

The same `@IDENT` token is an annotation when it precedes an
item and an effect marker when it follows a return type or
appears in an effect bound. The grammar production
distinguishes them; the casing rule (§"Casing convention")
prevents one name from inhabiting both namespaces.

Concretely:

```q64
@stage                          // ← annotation: @stage on the fn
fn render(scene: Scene) -> Frame @realtime + @no_alloc { … }
//                            ^^^^^^^^^^^^^^^^^^^^^^^   ← effect markers
```

A function-position name resolves first as an annotation; an
effect-position name resolves first as an effect marker. If a
lookup fails in the position-determined namespace, the compiler
does **not** fall back to the other — the diagnostic is
position-specific (`ANN001` vs. `EFF101`).

## Diagnostic codes

Annotation diagnostics use the `ANN` prefix; the prefix is
reserved in [`diagnostics.md` §"Code conventions"](./diagnostics.md).
Numbers are stable, never reused.

| Code     | Short message                                | When                                                                              |
|----------|----------------------------------------------|-----------------------------------------------------------------------------------|
| `ANN001` | unknown annotation                           | A lowercase `@foo` is not in the blessed catalog.                                 |
| `ANN002` | unknown property wrapper                     | A PascalCase `@Foo` has no in-scope wrapper declaration.                          |
| `ANN010` | annotation name violates casing convention   | Mixed-case (`@MyStage`, `@auto_Promote`) — lowercase or PascalCase, never mixed.  |
| `ANN020` | annotation in wrong position                 | `@stage` on a struct, `@shared` on a fn, etc.                                     |
| `ANN030` | annotation does not take arguments           | `@stage(...)` — `@stage` is bare-only.                                            |
| `ANN031` | annotation requires arguments                | `@derive` with no parens — at least one face required.                            |
| `ANN032` | duplicate annotation                         | The same annotation appears twice on one item.                                    |
| `ANN040` | declaration marker mixed with other annotations | `@allow @kind Foo` or `@managed @unit Foo : Hz`.                              |
| `ANN050` | property wrapper used outside a `struct` field | A PascalCase wrapper applied to a free `let` or a function parameter.           |
| `ANN060` | suggestion: prefer property wrapper          | (Note severity.) A field declares `let x: Signal<T, R> = …` where `@Signal x: T` would be more idiomatic. |

All codes are emitted using the standard envelope from
[`diagnostics.md`](./diagnostics.md). Cross-namespace codes
already exist for related concerns and are not duplicated:

- `EFF141` — `@CamelCase` used as a user-defined effect marker.
- `FMT060` / `FMT061` / `FMT062` — `@allow` misuse (per
  [`diagnostics.md`](./diagnostics.md)).
- `TYP214` — redundant `@no_derive` (per
  [`faces.md`](./faces.md)).

## User-defined annotations in v0

Only one category is open to user code:

- **Property wrappers (category 4).** Any PascalCase wrapper
  may be declared via comptime code in stdlib or user qubes.
  See the forthcoming `comptime.md` for the registration
  mechanism.

The other categories are closed for v0:

- **Compiler-known markers (category 1)** are bound to compiler
  features (effect analysis, stream graph construction,
  diagnostic suppression). Adding one requires a language
  revision.
- **Declaration markers (category 2)** introduce new nominal
  types and so participate in name resolution, monomorphization,
  and module visibility. A user-defined `@kind`-like form would
  require a comptime-declared item kind, which v0 does not
  support.
- **Derive forms (category 3)** are *user-extensible at the
  argument level* — a user-defined face may opt into being
  derived — but the `@derive` keyword itself is fixed.

User-defined **effects** (`pub effect @logging`,
`pub effect @audit`) are a separate surface; they are not
annotations. See [`effects.md` §"User-defined effects"](./effects.md).
The casing rule for user effect names is the same as for
annotations: lowercase only, with `EFF141` as the
casing-violation diagnostic.

## Examples

### A test function

```q64
@test
fn round_trip_json() {
    let original = User { name: "Alice", age: 30 }
    let encoded  = original.to_json()
    let decoded  = User.from_json(encoded)
    assert_eq(original, decoded)
}
```

### A struct with multiple categories

```q64
@managed                              // category 1 (storage)
@derive(Debug, Eq, Hash)              // category 3
struct Session {
    id:           SessionId,
    @Atomic count: u64,               // category 4 wrapper on a field
    @Lazy  cache: Map<Key, Value>,    // category 4 wrapper on a field
}
```

### A declaration marker

```q64
@unit Frames : Samples                // category 2 — introduces a new type
@kind UserId                          // category 2 — semantic newtype (forthcoming)
```

### A property wrapper with arguments

```q64
struct UiState {
    @Signal(rate = 60.Hz) mouse: Point,
    @Signal               focus: Option<WidgetId>,
}
```

### Casing-violation diagnostics

```q64
@MyStage                              // ❌ ANN010 — mixed case
fn render() { … }

@Foo                                  // ❌ ANN002 if no @Foo wrapper in scope
struct State { … }

@foo                                  // ❌ ANN001 — unknown lowercase marker
fn bar() { … }
```

### `@allow` for a known lint

```q64
@allow(CONC051)
fn drain(rx: Receiver<i64, Unbounded>) { … }      // suppresses the Unbounded-channel lint
```

## Open items deferred

- **Block-level `@allow`.** v0 attaches `@allow` to an item
  only. A future revision may permit `@allow(CODE) { … }` for a
  finer scope. Tracked in
  [`diagnostics.md`](./diagnostics.md).
- **Property-wrapper composition.** Whether `@Atomic @Lazy x:
  T` is meaningful and which order applies. Today only one
  wrapper per field; multi-wrapper is `ANN032`.
- **Conditional compilation markers** (`@target("browser")`,
  `@feature("foo")`). Sketched in
  [`modules.md`](./modules.md) and
  [`q64-cli.md`](./q64-cli.md); the eventual home is here once
  the conditional-compilation semantics are pinned.
- **`@deprecated`, `@inline`, `@public`.** Named in the design
  history but not in the v0 catalog. `pub` is the visibility
  keyword; `@inline` would be a codegen marker once codegen
  lands; `@deprecated` is a documentation-tooling concern.
- **Parameterized markers** (`@traced<level>`). Reserved for a
  v1 revision once user-defined parameterized effects land.
- **`@auto_promote`.** Tracked in
  [`types.md`](./types.md) §"Open items deferred"; would join
  category 1 if accepted.

## Related specs

- [`grammar.md`](./grammar.md) — the `Annotation` production
  and its arg forms; the position rule against effect markers.
- [`effects.md`](./effects.md) — the effect-marker namespace
  that shares the `@IDENT` lexical class; user-defined effects;
  the `EFF141` casing rule.
- [`diagnostics.md`](./diagnostics.md) — `@allow`; the
  diagnostic envelope; the `FMT06x` codes for `@allow` misuse.
- [`faces.md`](./faces.md) — `@derive`, `@no_derive`,
  `@skip_laws`; how face authors opt into derivation.
- [`memory.md`](./memory.md) — `@shared`, `@managed`,
  `@Atomic`.
- [`streams.md`](./streams.md) — `@stage`, `@fuse`, `@rate`;
  `@Signal`, `@Event`, `@Stream`.
- [`units.md`](./units.md) — `@unit` as a declaration marker.
- [`env.md`](./env.md) — `@Environment` (runtime-internal); the
  ambient capability story.
- [`errors.md`](./errors.md) — `@traced_panic`.
- [`concurrency.md`](./concurrency.md) — `@TaskLocal`.
