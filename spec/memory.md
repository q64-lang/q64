# Memory Model

How memory is organized in q64. Regions as the unifying abstraction;
the dual linear / managed heap; cross-region transfers; the multi-
memory layout; how `@send` is derived; and how shared state lives in
SAB-backed regions.

> **Status: draft (v0).** Ports the design discussion in
> `q64-lang/design`'s `memory.md` into spec form, then pins down
> three open calls (shared-region declaration via `@shared`, managed
> via `@managed`, cross-region transfer via a generic `transfer(…)`)
> that the narrative doc left as block-style sketches.

## Design goals

1. **Two heaps, both first-class.** Linear memory (allocator-managed,
   pointer-based) and WasmGC references (engine-collected) coexist.
   Neither is "the safe one" and neither is "the unsafe one."
2. **Regions are values with lifetimes.** Every allocation belongs to
   a region; the region owns the bytes; the region's lifetime bounds
   the value's lifetime.
3. **No hidden cross-heap moves.** Linear → managed and managed →
   linear conversions are explicit, named, and always copy.
4. **The platform layout is queryable, not surprising.** Region
   kinds map to distinct Wasm linear memories (`mem.stack`,
   `mem.arena`, …) so failure modes and diagnostics localize to
   the right backing memory.
5. **AI-agent friendly.** Region kind, sharedness, and managed-vs-
   linear status are all grep-able at declarations.

## Vocabulary

| Word                | Meaning                                                                       |
|---------------------|-------------------------------------------------------------------------------|
| **region**          | An allocator with a lifetime and a policy. Values "live in" a region.         |
| **region kind**     | Arena / Pool / Stack / Free-list / Managed — the strategy backing a region.   |
| **linear memory**   | Pointer-based Wasm memory (allocator-managed; freed by region exit).          |
| **managed memory**  | WasmGC references (engine-collected; per-Wasm-instance).                      |
| **`@send`**         | Derived predicate: this type's ownership may cross a thread boundary.         |
| **shared region**   | A region whose backing memory is SAB-shared across threads.                   |
| **`transfer`**      | The single generic cross-region/cross-heap copy primitive (see §Transfers).   |

## The platform: Wasm 3.0, dual address space (wasm32 / wasm64)

q64 targets core Wasm 3.0. Two of its features — **Memory64** and
**Table64** — define the *address space*, and that is a **per-build
choice, not a default**. Every build is compiled for exactly one
address space:

| Address space | Pointers | Memory64 / Table64 | Runs on Apple WebKit (Safari + every iPad/iOS browser) |
|---------------|----------|--------------------|--------------------------------------------------------|
| **`wasm32`**  | `i32`    | off                | **yes** — the universal baseline (linear memory ≤ 4 GiB) |
| **`wasm64`**  | `i64`    | on                 | **no** (as of 2026) — unlocks > 4 GiB on capable hosts |

There is **no default address space.** A build must name one
explicitly — via the target's `addressSpace`, or the `--addr` flag (see
[`qube.json5.md` §Targets](./qube.json5.md) and
[`q64-cli.md`](./q64-cli.md) / [`qube-cli.md`](./qube-cli.md)); q64
errors if neither resolves one. The rationale is compatibility:
Memory64 is **not** implemented in Apple's WebKit, so a silent 64-bit
default would emit qubes that cannot run on iPad/iOS — the very floor
the ecosystem targets. Forcing the choice makes every qube declare
where it can run, rather than discovering it at runtime.

The remaining Wasm 3.0 features q64 builds on are **independent of the
address-space choice** and present in both modes:

- **Multiple memories** — a core module declares several linear memory
  instances; q64 uses this to segregate region kinds.
- **WasmGC** — `struct.new`, `array.new`, engine-managed references.
- **Threads + atomics** — SAB-backed shared linear memory.
- **Stack-switching** — lightweight coroutine stacks.
- **SIMD** — 128-bit vector ops.

These choices compound. The dual-heap model is **what the platform
gives us**, not a compromise. The address-space split is the one place
the platform is *not* uniform — so q64 surfaces it rather than hiding
it: it shows up in the target, the build-output path, the synthesized
manifest, and (downstream) in how a deploy host such as qubepods stores
and serves the matching artifact.

### Address-space negotiation

A qube that publishes **both** a `wasm32` and a `wasm64` build is served
by capability, not by guesswork. The contract:

1. **The glue code probes the engine.** The loader — the browser host
   adapter (`runtime/browser/host.js`), or the gate/runtime in front of a
   deployed qube — tests for Memory64 support before fetching a module.
   The cheap, side-effect-free probe is to validate a tiny module that
   declares a 64-bit memory, e.g.
   `WebAssembly.validate(<(memory i64 1) module>)`; a `true` result means
   the engine can run `wasm64`. (Apple WebKit returns `false` as of 2026.)
2. **The glue code requests the right build.** It asks the store for
   `wasm64` only when the probe passed; otherwise it asks for `wasm32`.
3. **The store/registry falls back to `wasm32`.** If the requested build
   is missing — or the client sent no capability hint, or the hint is
   unknown — the serving layer returns the `wasm32` artifact. `wasm32` is
   the **universal safe fallback**: every engine can run it, so no client
   is ever left without a runnable build. The only unrunnable case is a
   qube that published `wasm64` *only* and a WebKit client — which is why
   the toolchain and manifest flag a wasm64-only qube as not-runnable-on-WebKit.

This keeps the negotiation simple: clients never parse modules to discover
the address space, the store never has to guess, and `wasm32` is always the
answer when anything is uncertain. The compiled artifacts themselves are not
stored in the Continuum (it holds **source** archives — see
[`continuum-api.md`](./continuum-api.md)); the dual-build store + per-request
selection live in the deploy host (on qubepods, the artifact store keyed by
the QubePod manifest's `component.variants`).

## Region kinds

| Kind          | Allocator        | Free strategy           | Concurrency                | Typical use                          |
|---------------|------------------|-------------------------|----------------------------|--------------------------------------|
| `Arena<N>`    | bump pointer     | all at region exit      | single-task only           | per-request, per-frame, per-tick     |
| `Pool<T, N>`  | fixed slot index | individual or at exit   | lock-free with reservation | message queues, frame pools          |
| `Stack`       | LIFO             | implicit on return      | strictly per-task          | local temporary buffers              |
| `FreeList`    | malloc-style     | individual              | single-task or locked      | general-purpose dynamic memory       |
| `Managed`     | engine (WasmGC)  | engine, async           | per-Wasm-instance          | long-lived graphs, cyclic structures |

Each kind is a concrete type fitting the auto-prelude face
`Region`. Generic code over "any region" uses the `R: Region`
parameter (per [`generics.md` §"The four parameter kinds"](./generics.md)).

The `Region` face is the compiler-blessed marker for "this
type is a region kind." It carries no user-visible methods in
v0; user code never writes `fit MyKind : Region`, because the
six blessed kinds (`Arena`, `Pool`, `Stack`, `FreeList`,
`Managed`, plus the `Interned<R>` target marker) are the only
inhabitants. The face exists so `R: Region` generic bounds and
the `region <name> : <kind> { … }` declaration form share a
single name in the type system. Adding new region kinds is a
language-level change (tracked under "Open items deferred").

The word "Region" therefore has three roles, easy to confuse:

| Use                                  | Meaning                                                                        |
|--------------------------------------|--------------------------------------------------------------------------------|
| `Region` (face)                      | The auto-prelude face every region kind fits. Used in bounds (`R: Region`).    |
| region kind                          | One of `Arena<N>`, `Pool<T, N>`, `Stack`, `FreeList`, `Managed`. A concrete type. |
| region binding                       | The named value introduced by `region <name> : <kind> { … }`. Lives in scope. |

The rest of this spec uses "the `Region` face," "a region kind,"
or "a region binding" — never bare "region" — when the
distinction matters.

## Region literal syntax

A `region` declaration introduces a named region whose lifetime is
the enclosing block:

```q64
region rt: Arena<1.MB> {
    let buf = Vec<u8>.new(rt)
    process(buf)
}                          // rt and everything in it freed at the closing brace
```

Form: `region <name> : <RegionKind> { <body> }`. The body sees
`<name>` as a value of type `<RegionKind>`. At the closing brace:

- Arena / Pool / Stack regions: bytes returned to the parent
  memory (or the OS, for top-level regions).
- FreeList regions: any still-live allocations cause `REG040`
  ("region exited with live allocations").
- Managed regions: the GC handle is dropped; the engine collects
  on its own schedule.

Nested regions inherit cancellation and panic-unwind behavior from
their enclosing scope (per [`concurrency.md`](./concurrency.md)).

### Scope's implicit arena

Every `scope { … }` block (per [`concurrency.md`](./concurrency.md))
carries a default `Arena`-kind region binding named `scope`. Code
that does not declare its own region uses this implicit one:

```q64
scope {
    let buf = Vec<u8>.new()             // allocates in scope's arena
    process(buf)
}                                       // arena freed here
```

Functions that don't take an explicit `R: Region` parameter allocate
into `scope` by default.

**Terminology.** "The scope arena" (used in `errors.md`,
`effects.md`, `concurrency.md`, `streams.md`) is the value of
this implicit binding at the nearest enclosing `scope { … }`. It
is always an `Arena<N>` kind. Panic payloads allocate here (per
[`errors.md` §`panic` and `trap`](./errors.md)); stage bodies
allocate here unless they name a different region. The binding
shadows lexically: a nested `scope { … }` introduces a fresh
`scope` binding whose lifetime is the nested block.

## The two heaps

**Linear memory**:

- Carved up by allocators (Arena / Pool / Stack / FreeList).
- Pointer-based; pointers are `i32` (`wasm32`) or `i64` (`wasm64`), per the build's address space (see §"The platform").
- Explicit lifetime; the owning region frees the bytes.
- Lowers to Wasm linear memory.
- Can be SAB-shared (see §Shared regions).

**Managed memory** (`Managed` kind):

- WasmGC references, opaque to user code.
- Engine-collected.
- Lowers to Wasm GC types (`struct.new`, `array.new`, `ref` types).
- Per-Wasm-instance (per-Worker in the browser). Cannot leave its
  thread without a `transfer`.

The heaps are **disjoint at the platform level**. Wasm 3.0 provides
separate instructions and separate memory areas. q64 surfaces the
boundary; there is no implicit pointer-to-reference conversion.

## Linear struct layout

How a `struct` value is laid out when it lives in linear memory (any
non-`Managed` region). Managed structs lower to WasmGC `struct.new`
and have no byte layout. The rules are deliberately C-like and
**stable**: layout is part of the platform contract (`q64 show layout
<type>` prints it), never a surprise.

1. **Declaration order is layout order.** Fields are placed in source
   order; the compiler never reorders. (Predictability over packing —
   a developer who wants a tighter struct reorders the declaration.)
2. **Natural size and alignment** per field type:

   | Field type                  | Size (bytes)        | Alignment        |
   |-----------------------------|---------------------|------------------|
   | `bool`, `i8`, `u8`          | 1                   | 1                |
   | `i16`, `u16`, `f16`         | 2                   | 2                |
   | `i32`, `u32`, `f32`         | 4                   | 4                |
   | `i64`, `u64`, `f64`         | 8                   | 8                |
   | `ref T`, pointer components | address-space width (4 on `wasm32`, 8 on `wasm64`) | same as size |
   | nested `struct`             | its own size        | its own alignment |

3. **Each field starts at the next multiple of its alignment** after
   the previous field's end (padding bytes are unspecified, not
   zeroed). A nested struct field embeds its bytes **inline**.
4. **Struct alignment = max field alignment**; **struct size is
   rounded up** to a multiple of the struct alignment. An empty
   struct has size 0, alignment 1.
5. **Allocation is aligned.** A region allocates a struct at an
   address that is a multiple of its alignment (the arena bump
   pointer rounds up before allocating).

Field access compiles to a load/store at `base + constant offset`.
Only pointer-bearing fields make a layout address-space-dependent;
a struct of scalars has identical layout on `wasm32` and `wasm64`.

**Values vs. addresses.** A record binding whose value never escapes
(no whole-value use: not passed, returned, nested, or referenced) may
be scalarized by the compiler (SROA) and never materialize in memory.
The layout above governs every value that does materialize: passed or
returned whole, stored in another struct, or referenced via `ref`.

> **Status (impl):** v0 lowers escaping record values into the scope
> arena (no reclamation yet), passes and returns them as a single
> pointer at the build's address width, and supports `i64` and `bool`
> fields; nested structs, `str`/`ref` fields, and `q64 show layout`
> are the next slices.

## Marking a struct managed

A `@managed` annotation marks a struct as living in WasmGC memory:

```q64
@managed
struct GameState {
    entities: Vec<Entity, Managed>,
    quadtree: ManagedBox<Quadtree>,
}
```

Effects of `@managed`:

- The struct may only be allocated via the `Managed` region's
  constructor `Managed.box(value) -> ManagedBox<T>`, which
  registers `value` as a fresh WasmGC root and returns a handle.
  There is no separate "shared managed" constructor in v0;
  cross-thread sharing of managed values requires
  `transfer(to: <thread-local Managed>)` on the receiving side
  (§"Cross-region transfers").
- Its fields must themselves be managed or be `Copy`-style
  value types (numerics, bool). A `ref` into linear memory is
  `TYP060`-equivalent in this spec: `REG020` ("linear pointer in
  managed struct").
- The struct is **not** `@send`, regardless of its field
  composition: WasmGC roots are per-Wasm-instance. See
  [`effects.md` §"Annotation carve-outs"](./effects.md).

This supersedes the `managed struct …` keyword form sketched in
`design.md`. The annotation pattern matches `@derive` and other
declaration-level annotations from
[`faces.md`](./faces.md).

## Region parameters in types

Allocating types take a region as a type parameter (per the
generics spec). The default is the enclosing scope's implicit
arena (§"Scope's implicit arena", above), spelled `scope`:

```q64
Vec<T, R: Region = scope>            // growable array
Map<K, V, R: Region = scope>         // hash map
Set<T, R: Region = scope>            // hash set
String<R: Region = scope>            // owned string
Box<T, R: Region = scope>            // single-value box
Bytes<R: Region = scope>             // owned byte buffer; alias for Vec<u8, R>
```

The names `Vec`, `Map`, `Set`, `Box`, `Bytes`, `String`,
`ManagedBox`, `Atomic`, and `Shared` are in the language
auto-prelude (per [`modules.md`](./modules.md) §"The
auto-prelude"). Their concrete fits live in the stdlib qube
`q64.collections` (compiled together with the language so the
prelude can re-export them), but no `import` is required at
the user side.

`R` is a compile-time identity that names a **specific region
value**, not a region kind. `Vec<i64, arena_a>` and
`Vec<i64, arena_b>` are different types; you cannot move data
between them without a `transfer(to: …)`.

### What "default region" means

The default `R = scope` resolves at each use site to the value
named `scope` in the enclosing block's lexical scope: the
implicit arena introduced by the nearest `scope { … }` (or the
function body's top-level scope) per §"Scope's implicit arena".

```q64
fn outer() {
    let a: Vec<i64> = Vec.new()        // a's R = the outer scope's arena
    inner_a(a)
    scope {
        let b: Vec<i64> = Vec.new()    // b's R = the inner scope's arena
        inner_b(b)
    }                                   // b's arena freed here
}
```

`a` and `b` are not the same type: their `R` parameters refer to
different region values. A function that takes `v: Vec<i64>`
without naming `R` introduces an anonymous generic
`<R: Region>` per [`generics.md` §"Implicit face
parameters"](./generics.md) — the caller passes a `Vec` from any
region, the callee is monomorphized per call site.

The Zig-style "thread the allocator through" escape hatch lets
libraries name `R` explicitly when they need to return a value
allocated in a caller-supplied region:

```q64
pub fn build_index<R: Region>(r: R, terms: [Term]) -> Index<R> {
    let idx = Index<R>.new(r)
    for t in terms { idx.insert(r, t) }
    idx
}
```

### Constructor calls with the default

A constructor like `Vec.new()` (with no `r` argument) allocates
into the binding-site's enclosing `scope` arena. The
desugaring is uniform: `Vec<T>.new()` ≡ `Vec<T, scope>.new(scope)`,
where `scope` on the RHS is the value of the implicit-arena
binding. A constructor called from a function that has named a
region parameter (`fn f<R: Region>(r: R)`) and supplies it
explicitly — `Vec<T, R>.new(r)` — bypasses the implicit-arena
sugar.

Methods that grow a collection follow the same rule. The
`Collection.push(self: ref Self, x: T)` signature takes no `r`
parameter when the collection's `R` is fixed at construction —
each `push` allocates into the region the `Vec` was originally
built with. Libraries that want to allocate into a *different*
region per push must use the explicit form
`Collection.push_into(self: ref Self, r: R2, x: T)` and accept
the resulting transfer cost.

## Cross-region transfers

The generic transfer primitive moves a value from one region to
another. Source and target kinds determine the semantics:

```q64
// Conceptual signatures, parameterized on the source's static type.
// The compiler synthesizes one specialization per source-region kind.
fn transfer<R2: Region>(self: Vec<u8, R1>, to: R2) -> Vec<u8, R2>
fn transfer<R:  Region>(self: str,         to: R)  -> String<R>
```

| Source kind  | Target kind  | Effective semantics                                 |
|--------------|--------------|------------------------------------------------------|
| Linear       | Linear       | Deep copy. Source remains valid in its region.       |
| Linear       | Managed      | Deep copy + register as GC root (formerly "pin").    |
| Static       | Linear       | Copy bytes into the target region.                   |
| Static       | Managed      | Copy + register as GC root.                          |
| Managed      | Linear       | Deep copy out of GC into the linear region.          |
| Static       | `Interned`   | Deduplicate; register canonical instance.            |

`Interned` is a target marker (not a region kind, strictly) that
selects deduplicating semantics: the target region keeps a hashtable
keyed by content hash, and `transfer(to: Interned<R>)` returns a
handle to the canonical instance — the second `transfer` of an
equal value re-uses the first allocation. It composes with
`Managed`: `"hello".transfer(to: Interned<Managed>)` deduplicates
inside the WasmGC heap. Hashtable lookup after the first allocation
is `@pure` (no further alloc).

The only verb is `transfer(to: …)`. `copy_to`, `pin_to`, and
`intern` are not in the language; the compiler rejects them as
unknown verbs (`REG050`).

### Examples

```q64
region arena1: Arena<1.MB> {
    let a: Vec<u8, arena1> = capture_buffer()

    region arena2: Arena<2.MB> {
        let b: Vec<u8, arena2> = a.transfer(to: arena2)     // deep copy
        send_to_thread(b.transfer(to: shared_pool))         // to a SAB pool
    }

    let c: ManagedBox<Vec<u8>> = a.transfer(to: Managed)    // pin into GC
}
```

The cost is visible: every cross-region step is a named call. An
`@realtime` stage cannot perform a transfer with unbounded size
(per [`effects.md`](./effects.md)) — `EFF110`.

## Lifetime tracking

Linear regions have explicit lifetimes; the compiler checks that
values do not outlive their region. Rules:

- A region's lifetime is the `region <name> : … { … }` block (or the
  enclosing `scope`'s arena for the implicit case).
- A value's lifetime is bounded by its region's lifetime.
- A function cannot return a value allocated in one of its **local**
  regions. The compiler diagnoses this at the `return` site as
  `REG010`.
- A function **can** return a value whose region was supplied by the
  caller (the standard Zig pattern):

```q64
pub fn parse<R: Region>(r: R, input: str) -> Tree<R> {
    Tree<R>.new(r, ...)         // Tree allocated in caller's region; safe to return
}
```

Managed types have no manual lifetime; the GC handles it. They are
not constrained by scope boundaries but cannot escape their Wasm
instance (their thread).

## Multi-memory architecture

> **Status (impl):** *not yet implemented — aspirational target.* Codegen emits a
> **single** linear memory today; the region kinds below are byte-offset regions
> within it (the bump-arena `sp` global, etc.). Multi-memory segregation is a
> deferred non-goal for now. Bulk-memory ops are enabled.

Wasm 3.0's multiple-memory feature lets q64 segregate region kinds
into distinct linear memory instances:

| Memory          | Backing kinds              | Notes                                                |
|-----------------|----------------------------|------------------------------------------------------|
| `mem.stack`     | Stack                      | Task stacks, one growable region per virtual thread. |
| `mem.arena`     | Arena                      | Per-scope bump arenas.                               |
| `mem.heap`      | Pool, FreeList             | Per-task pools and free-list regions.                |
| `mem.shared`    | shared regions             | SAB-backed; the only memory that pays SAB cost.      |
| `mem.large`     | any kind, > 1 MB allocs    | Fragmentation isolation.                             |
| `mem.rodata`    | Static / interned data     | Read-only; engine enforces.                          |

Benefits:

- **Failure isolation.** A stack overflow doesn't corrupt arenas;
  a free-list bug doesn't taint shared data.
- **Sharing cost paid where it's needed.** Only `mem.shared` is
  SAB-backed; thread-local memories don't pay SAB overhead.
- **Diagnostics localize.** Stack traces, heap dumps, and
  allocator reports name the originating memory.

User code never names a memory directly. The multi-memory layout
shows up in `q64 show memories` (per
[`q64-cli.md`](./q64-cli.md)) and in diagnostics.

## `@send` derivation

`@send` is a type-level predicate. The derivation rules and the
`q64 show send <type>` introspection are normatively specified in
[`effects.md` §"The `@send` story"](./effects.md); this section
records only the region-level inputs the derivation consumes:

- **Linear regions** are *single-owner* — a value allocated in
  `Arena` / `Pool` / `Stack` / `FreeList` is `@send` if and only
  if its `T` is `@send` and the region's handle is itself
  `@send` (i.e., the region is not borrowed by a task other than
  the current one).
- **Shared regions** (`@shared` structs, backed by `mem.shared`)
  are *sharable* — their handle is `@send` by construction, so
  `Vec<T, R>` in a shared region is `@send` whenever `T` is.
- **Managed memory** (WasmGC) is **per-Wasm-instance**. Any type
  whose composition includes a managed reference (a `ManagedBox<T>`,
  a `Vec<T, Managed>`, a `@managed` struct) is **not** `@send`.
  Crossing a thread boundary with such a value requires
  `transfer(to: <thread-local Managed>)` on the receiving side
  (see §"Cross-region transfers").

`effects.md` enumerates the full struct / enum / parameter
composition rules and defines the `EFF113` / `EFF114`
diagnostics; this spec does not duplicate them.

## Shared regions

A shared region's backing memory lives in `mem.shared` and is
visible to every Wasm thread. Declared with `@shared` on a struct:

```q64
@shared
struct World {
    counter: Atomic<i64>,
    grid:    Shared<Grid>,
}

scope {
    let world = World.new()
    spawn { world.counter.add(1) }
    spawn { world.counter.add(1) }
}
```

Effects of `@shared`:

- The struct is allocated in `mem.shared` (SAB-backed in the
  browser; `pthread_mutex`-protected linear memory in Wasmtime /
  Wasmer).
- Every field must be `Atomic<T>`, `Shared<T, P>`, or another
  `@shared` struct. A plain field is `REG030` ("non-shareable field
  in @shared struct").
- The struct is `@send` (its handle can cross threads freely).
- Field access compiles to atomic loads/stores or to
  `Shared<T, P>`-policy operations (Mutex / RwLock / LockFree /
  Disjoint).

This supersedes the `shared_region world { … }` block form sketched
in `design.md`; the annotation pattern is consistent with
`@managed` above.

### `Shared<T, P>` policies

```q64
Shared<T, Mutex>          // exclusive access, blocking
Shared<T, RwLock>         // many readers or one writer
Shared<T, LockFree>       // requires T: Atomic or T: ImmutableSnapshot
Shared<T, Disjoint<F>>    // compile-time-verified disjoint field access
```

`Atomic<T>` is the primitive for shared scalars. The blessed
payload types in v0 are the integer tower (`Atomic<i32>`,
`Atomic<i64>`, `Atomic<u32>`, `Atomic<u64>`) and `Atomic<bool>`.
Backed by Wasm 3.0 atomic ops. Methods: `load() -> T`,
`store(v: T)`, `add(v: T) -> T`, `sub(v: T) -> T`,
`compare_exchange(expected: T, new: T) -> T` (returns the prior
value), plus the bitwise variants on integer payloads (`or`,
`and`, `xor`). Atomic pointer-sized handles (e.g. atomic
references into shared regions) are deferred until the shared-
reference design lands.

**Memory ordering, v0.** Every `Atomic<T>` operation uses
**sequentially-consistent** ordering — the strongest Wasm 3.0
ordering. Conservative-by-default; a future revision may add
`@relaxed` / `@acquire` / `@release` annotations on individual
operations for hot paths that have measured the need. v0 picks
correctness over peak throughput.

Most user code uses `Shared<T, Mutex>` or `Atomic<T>`. LockFree
and Disjoint are advanced; they enable hot paths the compiler can
prove safe without runtime checks.

## Allocator parameters as cultural pattern

Zig's influence, generalized: anything that allocates takes the
region as a parameter when the caller wants control:

```q64
pub fn intern<R: Region>(r: R, s: str) -> String<R>
pub fn merge_sort<T, R: Region>(r: R, items: [T]) -> Vec<T, R>
pub fn collect<T, R: Region>(r: R, stream: Stream<T>) -> Vec<T, R>
```

This appears in libraries where allocation strategy matters and
in stdlib code that wants to be generic. Application code with no
strong preference falls back to the implicit `scope` arena and
omits `R`.

## Effect interactions

Memory operations carry the effects from
[`effects.md`](./effects.md):

| Operation                        | Effects                                |
|----------------------------------|----------------------------------------|
| Arena / Pool / Stack alloc       | Allocates ⇒ violates `@no_alloc`.      |
| FreeList alloc                   | Allocates ⇒ violates `@no_alloc`.      |
| Managed alloc                    | Allocates + may suspend (GC) ⇒ `@no_suspend` violation as well. |
| `transfer(to: linear)`           | Allocates in target; unbounded size ⇒ `EFF110` if `@realtime`. |
| `transfer(to: Managed)`          | Allocates + may suspend ⇒ both effects. |
| `transfer(to: Interned<…>)`      | Allocates first time; hashtable lookup is `@pure` after. |
| `Atomic<T>.load/store/cas`       | `@no_alloc` + `@no_suspend` ✓ — safe inside `@realtime`. |

The `@realtime` audio path may allocate **nothing** at run time.
That means: a `transfer` cannot appear in a `@realtime` stage; the
audio thread reads from `Pool`-backed channels and operates on
already-positioned buffers.

## Diagnostic codes

All region-and-lifetime diagnostics use the `REG` prefix. Numbers
are stable, never reused. `REG040`–`REG099` reserved for future
expansion.

| Code     | Short message                                | When                                                                              |
|----------|----------------------------------------------|-----------------------------------------------------------------------------------|
| `REG010` | value outlives its region                    | A function returns a value allocated in one of its local regions.                  |
| `REG011` | borrowed value escapes its region            | A `ref` to region-local data is stored outside that region.                        |
| `REG012` | cross-region pointer without transfer        | A function takes `Vec<u8, R1>` but is called with `Vec<u8, R2>`.                   |
| `REG013` | implicit-scope arena allocation in `@no_alloc` function | An unannotated allocation appears under `@no_alloc`.                  |
| `REG020` | linear pointer in `@managed` struct          | A `@managed` struct has a field pointing into linear memory.                       |
| `REG021` | managed reference in non-managed struct      | A plain struct has a managed-reference field; whole struct must be `@managed`.    |
| `REG030` | non-shareable field in `@shared` struct       | A field whose type isn't `Atomic<T>` / `Shared<T, P>` / `@shared`.                  |
| `REG031` | `@shared` struct passed by linear value       | A `@shared` struct can only be referenced through its handle, not copied by value.|
| `REG032` | shared region escapes its scope               | A `@shared` value crosses into a scope where its backing memory isn't visible.   |
| `REG040` | region exited with live allocations           | A `FreeList` region exited without explicit frees for some allocations.            |
| `REG041` | nested region outlives parent                 | A region tries to outlive the region that owns its backing memory.                |
| `REG042` | invalid region kind for operation             | E.g. `Stack` region passed where a growable region is required.                    |
| `REG050` | unknown transfer verb                         | Source uses `copy_to` / `pin_to` / `intern` instead of `transfer(to: …)`.          |

All codes are emitted using the standard envelope from
[`diagnostics.md`](./diagnostics.md).

## Examples

### Per-frame arena in a renderer

```q64
fn render_frame(scene: Scene) -> Frame {
    region frame_arena: Arena<8.MB> {
        let visible = scene.cull(frame_arena)            // Vec<Object, frame_arena>
        let cmds    = build_command_list(frame_arena, visible)
        let pixels  = rasterize(frame_arena, cmds)

        // Pixels need to escape; transfer to caller's scope arena.
        pixels.transfer(to: scope)
    }
}
```

Everything inside the `region` block is freed at the closing brace
except `pixels`, which the explicit `transfer` copies out.

### Managed graph with cycles

```q64
@managed
struct Node {
    children: Vec<ManagedBox<Node>>,
    parent:   Option<ManagedBox<Node>>,
}

fn build_tree() -> ManagedBox<Node> {
    let root  = Managed.box(Node { children: Vec.new(), parent: None })
    let child = Managed.box(Node { children: Vec.new(), parent: Some(root) })
    root.children.push(child)
    root
}
```

`child` points back to `root` via `parent`; `root` points to
`child` via `children`. That's a cycle in the object graph — fine
under WasmGC, which collects the whole subgraph once no managed
reference reaches it. A linear-memory allocator couldn't free
this without a topological owner; the managed heap is the escape
hatch for graphs the developer doesn't want to discipline by
hand.

### Shared counter across tasks

```q64
@shared
struct Hits {
    count: Atomic<i64>,
}

scope {
    let hits = Hits.new()
    for _ in 0..100 {
        spawn { hits.count.add(1) }
    }
    // structured scope joins; at this point hits.count == 100
}
```

### Real-time audio path — pool-backed channel

```q64
fn audio_engine {
    region pool: Pool<Frame, 64> {                      // 64 slots, lock-free
        let (tx, rx) = channel<Frame>(pool, policy: RingBuffer, capacity: 64)

        spawn { capture_loop(tx) }                      // producer; allocates into the pool

        scope @realtime {
            loop {
                let frame: Frame = rx.recv()             // RingBuffer recv takes no ctx
                play(frame)                              // @realtime; no allocation
            }
        }
    }
}
```

The pool lives outside the `@realtime` scope; the audio loop only
reads from pre-allocated slots. `transfer` does not appear in the
hot path.

## Open items deferred

- **Region parameter inference at call sites.** Today the caller
  passes `R` explicitly (or relies on `Arena` default). A future
  pass may infer `R` from the binding-type context.
- **First-class region polymorphism in faces.** A face whose
  methods take `r: R` parameter for arbitrary `R` works today;
  faces with associated regions (`type R: Region`) are deferred.
- **Borrow checker for cross-region references.** v0 forbids
  cross-region references statically (`REG011` / `REG012`); a
  future revision may permit them via explicit lifetime
  annotations.
- **Specialization of `transfer` semantics.** Optimizing
  `Linear → Managed` for small POD types (avoiding the GC root
  registration) and similar peephole improvements; tracked by the
  faces.md specialization deferral.
- **Custom region kinds via user types.** Today `Arena`, `Pool`,
  `Stack`, `FreeList`, `Managed`, `Interned` are blessed. Letting
  user libraries declare new `R: Region` kinds requires more
  thought about layout, `@send`, and the `transfer` table.
- **Drop semantics on region exit.** A FreeList region with live
  allocations could call user-defined destructors instead of
  raising `REG040`; deferred until the broader destructor design
  lands.

## Related specs

- [`effects.md`](./effects.md) — `@send` derivation, allocation
  effects, transfer effects in `@realtime` paths.
- [`generics.md`](./generics.md) — the `R: Region` parameter
  kind, default region parameters on collections, region face
  bounds.
- [`concurrency.md`](./concurrency.md) — scope's default arena,
  structured concurrency interaction with regions, `@shared` regions
  and channels, atomics.
- [`faces.md`](./faces.md) — `Region` is an auto-prelude face;
  `Arena`, `Pool`, `Stack`, `FreeList`, `Managed`, `Interned` are
  blessed types fitting it.
- [`modules.md`](./modules.md) — `Region` and the region kinds are
  in the auto-prelude; no import required.
- [`q64-cli.md`](./q64-cli.md) — `q64 show regions <fn>`,
  `q64 show alloc <fn>`, `q64 show layout <type>`,
  `q64 show memories` introspection.
- [`diagnostics.md`](./diagnostics.md) — envelope format for the
  `REG*` codes.
