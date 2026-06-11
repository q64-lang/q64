# Modules and Visibility

How q64 source is organized into modules, how modules import each other,
and how visibility controls what crosses file and qube boundaries.

> **Status: near-final (v0).** The decisions captured here have been
> resolved; field-level visibility on structs is deferred to the
> [faces/types spec](./faces.md) and is not covered here.

## Design goals

1. **Greppable symbol provenance.** Given any identifier in a source file,
   one of three lines reveals where it came from: its own declaration in
   this file, an `import` statement at the top, or the language's
   auto-prelude. No fourth channel.
2. **Two visibility levels.** `pub` or file-private. No `pub(crate)` /
   `pub(super)` / `pub(qube)` ladder.
3. **Mechanically refactorable.** Renaming a file, moving a sub-module,
   or extracting a helper must be a localized edit — never a
   project-wide hunt for transitive name leaks.
4. **AI-agent friendly.** An LLM should be able to read a file cold and
   know its public API in one glance, and read an import line and know
   exactly which symbols it brings in.

These goals push every decision toward "explicit, named, local."

## Modules and module paths

### Module identity

| On disk                           | Module path           |
|-----------------------------------|-----------------------|
| `<qube>/src/lib.q`                | `<qube-name>`         |
| `<qube>/src/main.q`               | `<qube-name>` (application qubes; no library entry) |
| `<qube>/src/<name>.q`             | `<qube-name><name>`  |
| `<qube>/src/<dir>/lib.q`          | `<qube-name><dir>`   |
| `<qube>/src/<dir>/<name>.q`       | `<qube-name><dir><name>` |

Folder = sub-namespace. `lib.q` inside a folder is the entry point when
the folder is imported by name. A folder without a `lib.q` is still
navigable to its files but cannot itself be imported.

### Qube name = module path

A qube's name **is** its module path — there is no transform. Names are
reverse-DNS dotted paths whose segments are lowercase identifiers
(`[a-z][a-z0-9_]*`, snake_case, no dashes), so the string in `qube.json5`,
in `dependencies`, on the registry URL, and in an `import` are byte-for-byte
identical:

| Qube name (`qube.json5`)   | Import path root           |
|----------------------------|----------------------------|
| `dev.q64.webmcp_client`    | `dev.q64.webmcp_client`    |
| `com.acme.widget_kit`      | `com.acme.widget_kit`      |

`q64.*` is reserved for the built-in standard library (`q64.math`,
`q64.net`, `q64.io`, …): it ships with the toolchain, is resolved
internally, and is never published to the Continuum or listed in
`dependencies`. Everything published uses a reverse-DNS namespace the
publisher owns (first-party q64 libraries live under `dev.q64.*`).

Because identifiers can't contain `-`, names can't either (a dash in a
bare module path is `NAM011`).

### Module-header doc comment (optional)

The first lines of a file may contain a `//!` doc comment summarizing
the module:

```q64
//! q64.math.vec — Three-dimensional vector arithmetic with units.
//! exports: Vec3, dot, cross, normalize
```

This is **informational**, not enforced. The compiler ignores the
`exports:` line for visibility purposes — only `pub` declarations
actually control what's exported. The header drives `q64 show modules`
output and LSP hover/summary panels.

## Import grammar

### Three forms

```q64
import <module-path>                       // namespace import
import <module-path>.{ <name>, ... }       // selective import
import <module-path> as <ident>            // aliased namespace
```

`<module-path>` is one of:

- **Bare dotted** — `q64.math.vec`. Resolves through the current qube's
  `qube.json5` `dependencies` map (or, for paths beginning with this
  qube's own name, internally).
- **Quoted relative** — `"./vec.q"`, `"../shared/util.q"`. Resolves
  relative to the current file. Cannot escape the current qube
  (paths that would leave the qube root are a `NAM002` error).

The two path kinds are distinguished by whether the path begins with `"`.
This is a mechanical syntactic rule with no overlap.

### Naming the bound symbol

| Form                                            | Bound names                                                         |
|-------------------------------------------------|---------------------------------------------------------------------|
| `import q64.math.vec`                           | `vec` (last segment of the path) as a namespace                     |
| `import q64.math.vec.{Vec3, dot}`               | `Vec3` and `dot` directly                                           |
| `import q64.math.vec as v`                      | `v` as a namespace                                                  |
| `import "./util.q"`                             | `util` (filename without `.q`) as a namespace                       |
| `import "./util.q".{helper, Token}`             | `helper` and `Token` directly                                       |
| `import "./util.q" as u`                        | `u` as a namespace                                                  |

Selective and aliased forms do **not** compose with each other —
`import x.{a} as y` is a syntax error. Choose one binding mode per
import line.

### Forbidden

```q64
import q64.math.*                          // ❌ NAM003 (wildcard forbidden)
import "./util.q".*                        // ❌ NAM003 (wildcard forbidden)
import x.{a} as y                          // ❌ NAM004 (selective with alias)
import "../../../other-qube/src/foo.q"     // ❌ NAM002 (path escapes qube)
```

Wildcards are forbidden in every form. Every identifier visible in a
file is either declared in that file, named at an import, or part of
the language's auto-prelude (see §"The auto-prelude" below).
`grep <Name>` always finds the import line.

### Collisions

If a selective import or a top-level declaration would bind a name
already in scope, the compiler rejects it as `NAM005`. Use
aliasing to disambiguate:

```q64
import "./a.q".{Frame}
import "./b.q".{Frame}                     // ❌ NAM005 (name collision)

import "./a.q".{Frame}
import "./b.q" as b                        // ✓ refer to b.Frame
```

## Visibility

Every item declaration carries an optional `pub` prefix:

```q64
pub fn dot<T>(a: Vec3<T>, b: Vec3<T>) -> T { ... }
pub struct Vec3<T> { x: T, y: T, z: T }
pub enum Color { Rgb, Hsv, Lab }
pub type Hz = f64
pub face Eq { ... }
pub fit Vec3<f32> : Eq { ... }
pub const PI: f64 = 3.14159
pub use Vec3 from "./vec.q"

fn helper() -> i64 { ... }                   // file-private (no pub)
```

- An item without `pub` is **file-private**. It is not visible to
  sibling files in the same qube, regardless of how those files import
  this one.
- An item with `pub` is visible to any code that imports its containing
  module by any of the three import forms. Crossing the qube boundary
  additionally requires a chain of `pub use` re-exports starting at the
  qube's entry point (`src/lib.q` or `src/main.q`) — see "The re-export
  wall," below.

### Block `pub` is forbidden

```q64
pub { fn a() ... fn b() ... }              // ❌ NAM009 (block pub forbidden)
```

Every public item must start its line with `pub`, so `grep '^pub '`
enumerates a file's contributions to the public surface.

### Field visibility on structs

Out of scope for this spec. Struct fields inherit the struct's
visibility in v0: fields of a `pub struct` are publicly readable.
Per-field visibility (`pub` on each field, or an explicit `private`
marker) is deferred to a future per-field-visibility spec and will not
break existing code when it lands.

## The auto-prelude

A small set of names is in scope in every file without an `import`
line. Each category is owned by the spec that introduces it; this
section indexes them.

| Category               | Names                                                          | Owning spec                                          |
|------------------------|----------------------------------------------------------------|------------------------------------------------------|
| Numeric primitives     | `i8`–`i64`, `u8`–`u64`, `f16`/`f32`/`f64`, `bool`              | [`types.md`](./types.md) §"The numeric tower"        |
| Strings                | `str`, `String`                                                | [`types.md`](./types.md) §"Strings: `str` and `String<R>`" |
| Bindings & arrays      | `let`, `var`, `[T]`, `[T; N]`, `ref`                           | [`types.md`](./types.md) §"Bindings", §"Arrays and slices", §"References" |
| Compound numerics      | `Simd`, `Tensor`, `DynTensor`                                  | [`types.md`](./types.md) §"SIMD and Tensor as language types" |
| Optionality / errors   | `Option` (+ `Some`/`None`), `Result` (+ `Ok`/`Err`), `T?`, `try`, `panic`, `trap`, `PanicMessage`, `Cancelled`, `Closed`, `RuntimeDenied`, `RangeError` | [`errors.md`](./errors.md) §"Auto-prelude additions" |
| Auto-prelude faces     | `Eq`, `Ord`, `Hash`, `Clone`, `Display`, `Debug`, `Iterator`, `Default`, `From`, `Into`, `TryFrom`, `TryInto`, `Arbitrary`, `Error`, `Panic` | [`faces.md`](./faces.md) §"Auto-prelude faces" + [`errors.md`](./errors.md) + [`test-framework.md`](./test-framework.md) (`Arbitrary` face) |
| Collections            | `Vec`, `Map`, `Set`, `Box`, `Bytes`                            | [`memory.md`](./memory.md) §"Region parameters in types" |
| Regions                | `Region`, `Arena`, `Pool`, `Stack`, `FreeList`, `Managed`, `Interned`, `scope`, `transfer` | [`memory.md`](./memory.md) §"Region kinds"     |
| Shared memory          | `Atomic`, `Shared`, `ManagedBox`, `Mutex`, `RwLock`, `LockFree`, `Disjoint` | [`memory.md`](./memory.md) §"Shared regions", §"`Shared<T, P>` policies" |
| Capabilities           | `Env`, `Net`, `Fs`, `Audio`, `Midi`, `AiEnv`, `Ui`, `Clock`, `Rng`, `Stdout`, `Stderr`, `ExitFn`, `EnvVars`, `with_capabilities` | [`env.md`](./env.md) §"`Env` and its fields" |
| Concurrency primitives | `scope`, `spawn`, `channel`, `select`, `actor`, `tell`, `ask`, `Cancel`, `Handle`, `Future`, `Sender`, `Receiver`, `Policy`, `CancelPolicy`, `NonCancelPolicy`, `Backpressure`, `RingBuffer`, `LatestValue`, `Unbounded`, `timeout`, `sleep`, `SendError`, `RecvError` | [`concurrency.md`](./concurrency.md)            |
| Stream primitives      | `Signal`, `Event`, `Stream`, `SharedSignal`, `Graph`, `@stage`, `graph`, `pre`, `\|>`, `changes`, `hold`, `fold`, `sample` | [`streams.md`](./streams.md)                |

`scope` deliberately appears in **two** rows of the table: the
"Regions" row covers the implicit `Arena`-kind region binding the
keyword introduces (per [`memory.md` §"Scope's implicit arena"](./memory.md)),
and the "Concurrency primitives" row covers the `scope { … }`
block form itself (per [`concurrency.md` §"Scopes"](./concurrency.md)).
The two uses share an identifier on purpose — the arena is named
after the block that owns it — and LSP hover disambiguates by
syntactic position (block-introducing keyword vs. value-bound name).

### Reachable through a capability face

Capability faces (`Net`, `Fs`, `Audio`, …) carry parameter and
return types — `Url`, `Response`, `IoError`, `WebSocket`,
`JsonError`, `MidiMessage`, `Frame`, `Token<V>`, etc. Because
the face is auto-prelude, the **types in its public-facing
signatures are also auto-prelude**: any type that appears in a
prelude face's method signatures, in the return type of a
constructor on a prelude type, or as a variant payload of a
prelude enum, is itself reachable without an import.

This is the only transitive auto-prelude rule. It exists so that
`env.net.get(url"…")` doesn't require importing `q64.net.Url`,
`q64.net.Response`, and `q64.net.IoError` to type-check the call.
The reachable set is computed by the compiler and surfaced by
`q64 show modules --prelude` for auditing.

The transitive rule does **not** apply to stdlib types that are
not in the prelude faces' signatures — `Mat4`, `Quat`, etc. from
`q64.math` require explicit import.

### Typed-prefix string literals

The `url"…"` typed prefix (and any future typed prefix like
`re"…"`, `sql"…"`) is in the auto-prelude exactly when the
corresponding type is reachable per §"Reachable through a
capability face". `url"…"` is auto-prelude because `Url` shows
up in `Net.get`'s signature; `re"…"` would become auto-prelude
once a regex type is similarly exposed.

### Notes on what is **not** auto-prelude

- `Convert<From, To>` — multi-parameter face; per `faces.md`,
  every use should make the import explicit.
- Stage-classification faces (`Source`, `Sink`, `RateAware`) —
  deferred per `faces.md` §"Open items deferred".
- Anything from the stdlib namespaces (`q64.math`, `q64.net`,
  `q64.fs`, …) **not** reachable through a prelude face — those
  require explicit `import`.

The prelude is curated; user code cannot add to it. New blessed names
land via spec amendment in the owning file and are mirrored here.

## Re-exports — `pub use`

A re-export brings a name from another module into the current module's
public surface:

```q64
pub use Vec3 from "./vec.q"                       // single name
pub use Vec3, dot, cross from "./vec.q"           // multiple names
pub use vec from "./vec.q"                        // re-export the whole namespace under its own name
pub use vec as v3 from "./vec.q"                  // re-export under a different name
pub use Vec3 from q64.math.vec                    // re-export a name from another qube
```

A re-exported name is indistinguishable from a direct declaration as
far as consumers are concerned. There is no "this came via re-export"
marker in the consumer-visible API.

Re-exports may chain (a re-export of a re-export is fine); cycles in
re-export chains are a `NAM008` error.

### The re-export wall

A qube's public surface is exactly what is transitively reachable
through `pub use` chains starting at its entry point (`src/lib.q` for
libraries, `src/main.q` for applications).

```q64
// stdlib/math/src/vec.q
pub fn private_to_qube() -> i64 { ... }      // pub, but never re-exported

// stdlib/math/src/lib.q
pub use Vec3, dot, cross from "./vec.q"    // these three escape
```

From a caller in another qube:

```q64
import q64.math.{Vec3, dot, cross}         // ✓ all three are re-exported
import q64.math.{private_to_qube}          // ❌ NAM006 (private to qube)
import q64.math.vec.{private_to_qube}      // ❌ NAM007 (sub-module not re-exported from lib.q)
```

This is the "two visibility levels" decision realized. There is no
`pub(qube)` keyword; the qube boundary is defined by what `lib.q`
re-exports, not by a third level of marker.

### Sub-module reachability

A sub-module (`q64.math.vec`) is reachable from outside its qube
exactly when **the entry point's re-export chain transitively
names it** — either as a re-exported sub-namespace
(`pub use vec from "./vec.q"`) or by re-exporting one or more
names *from* it (`pub use Vec3 from "./vec.q"`). Re-exporting any
name from a sub-module also exposes the sub-module's namespace
path for selective imports of its other re-exportable names:

```q64
// stdlib/math/src/lib.q
pub use Vec3, dot, cross from "./vec.q"        // exposes q64.math.vec
```

From another qube:

```q64
import q64.math.vec.{Vec3}                     // ✓ vec is exposed (lib.q pulls names from it)
import q64.math.vec.{Vec3, dot}                // ✓ same
import q64.math.vec.{private_to_qube}          // ❌ NAM007 — vec is exposed,
                                               //    but private_to_qube was not re-exported from lib.q
```

A sub-module from which no name is re-exported is invisible
across the qube boundary (`NAM007`); a sub-module from which any
name is re-exported is *navigable* across the boundary, but the
re-export wall still applies per-name. Selective imports of
unre-exported names are `NAM007`, never `NAM010` — the missing
ingredient is the re-export, not the declaration.

## The qube as a component (opt-in)

A qube's default build artifact is a **core module** (per
[`README.md` §"Wasm 3.0 is the platform"](./README.md)). When component
emission is requested — `qube build --component`, or `component.emit: true`
in the manifest ([`qube.json5.md` §Component](./qube.json5.md)) — q64 wraps
that unmodified core module in a WebAssembly **component** whose **WIT
`world` is synthesized, not authored**:

- **Exports** = the qube's public surface — exactly the names reachable
  through the re-export wall above. No new visibility concept: the component
  export set *is* the existing `pub use` surface.
- **Imports** = the qube's compiler-derived capability set (per
  [`env.md` §"Inferred capability set"](./env.md) and the effect→WIT-import
  table in [`effects.md` §"Effects and the Component Model"](./effects.md)).

The core module is always the primary artifact; the component embeds it and
adds canonical-ABI lifting glue. The default build is unaffected.

### Lowering q64 types to the canonical ABI

A `pub` function may be a component export only if its parameter and return
types lower to the WIT canonical ABI. The mapping:

| q64 type | WIT type |
|----------|----------|
| `i8`…`i64`                 | `s8`…`s64`           |
| `u8`…`u64`                 | `u8`…`u64`           |
| `f32`, `f64`               | `f32`, `f64`        |
| `bool`                     | `bool`              |
| `str`, `String`            | `string`            |
| `[T]`                      | `list<T>`           |
| `Bytes`                    | `list<u8>`          |
| `Option<T>`                | `option<T>`         |
| `Result<T, E>`             | `result<T, E>`      |
| struct                     | `record`            |
| enum (data-free)           | `enum`              |
| enum (with payloads)       | `variant`           |

**Unlowerable** — these cannot cross the canonical ABI and a `pub` function
using one in its signature is rejected when component emission is on (a
`CMP`-band diagnostic per [`diagnostics.md`](./diagnostics.md)):
`ref T` (borrows are region-local), region-parameterized types, managed /
WasmGC references, closures, and faces-as-values. WIT `resource`s are an
adapter-internal concept and are likewise never part of a q64 export
signature (see [`env.md`](./env.md)).

### `@no_component_lift`

The `@no_component_lift` annotation (per [`annotations.md`](./annotations.md))
excludes a `pub` function from the component export surface: it stays
callable inside the core module but is not lifted across the canonical ABI.
**Every `@realtime` function is implicitly `@no_component_lift`** — canonical-
ABI lifting copies/allocates at the boundary, which violates `@realtime`'s
no-alloc/no-suspend contract (per [`effects.md`](./effects.md) and
[`env.md` §"`@realtime` and capabilities"](./env.md)). Real-time code thus
never crosses a component boundary; it is reachable only from within the
core module.

### The world is also the RPC contract

The same synthesized `world` is the contract q64 uses for qube-to-qube
**RPC** (see [`rpc.md`](./rpc.md)): a qube that *imports* a remote qube's
world calls its exports as ordinary functions that carry the `@wire` effect,
and the canonical-ABI value encoding above doubles as the wire format. An
imported remote qube therefore appears in this qube's world as an import,
exactly like a capability. No separate IDL is authored.

## Resolution algorithm (overview)

For an import `import <path>` in a file at `<file-path>`:

1. **If `<path>` is quoted relative**, resolve it as a filesystem path
   relative to `<file-path>`. The resolved file must lie within the
   current qube's source root.
2. **If `<path>` is bare dotted**, split off the leading qube name:
   - If the qube name is the current qube's own name (per
     `qube.json5`), resolve the rest of the path as
     `<qube-root>/src/<segments>/...`.
   - Otherwise, look up the qube name in the current qube's
     `dependencies` map. The compiler's `--module <name>=<dir>` flag
     (per [`q64-cli.md`](./q64-cli.md)) provides the resolved
     directory for each dependency.
3. **Resolve the trailing segments** by alternating: each segment
   matches either a `<seg>.q` file in the current directory, or a
   `<seg>/` directory containing a `lib.q` file.
4. **Apply the binding mode** (namespace, selective, alias) to the
   resolved module.

Diagnostic codes for the failure modes are listed in the next section.

## Diagnostic codes

All `NAM*` codes for module resolution errors. Numbers are stable and
never reused.

| Code     | Short message                          | When                                                                              |
|----------|----------------------------------------|-----------------------------------------------------------------------------------|
| `NAM001` | unknown module                         | Module path does not resolve to a known qube or path.                             |
| `NAM002` | import path escapes qube               | Quoted relative path escapes the current qube root.                               |
| `NAM003` | wildcard import is forbidden           | `*` appeared in an import specifier.                                              |
| `NAM004` | selective import combined with alias   | `import x.{a} as y` — pick one binding mode.                                      |
| `NAM005` | name collision in import scope         | Two imports (or an import and a declaration) bind the same name in this file.     |
| `NAM006` | name is private to its qube            | Selective import of a name that exists in the source qube but is not re-exported. |
| `NAM007` | sub-module not re-exported             | Attempt to import a sub-module that is not re-exported from the qube entry.       |
| `NAM008` | re-export cycle                        | `pub use` chains form a cycle.                                                    |
| `NAM009` | block `pub` form is forbidden          | `pub { … }` block form encountered; use per-item `pub`.                           |
| `NAM010` | unknown name in source module          | Selective import named an identifier not declared in the source module.           |
| `NAM011` | dash in bare module path               | Bare module path contains `-`. Qube/module names use `_`, not `-` (a dash lexes as the minus operator). |

All codes are emitted using the standard envelope from
[`diagnostics.md`](./diagnostics.md), with `severity: "error"`. The
short message is the diagnostic's `message` field; the code is the
`code` field; tooling-friendly identifiers (like `wildcard-forbidden`)
may be surfaced through `repair.id` when an autofix is available.

## Examples

### Minimal application

```
hello/
├── qube.json5     (type: "application")
└── src/main.q
```

```q64
//! hello — entry point.

fn main {
    env.out("Hello, q64.")
}
```

No `import`, no `pub`.

### Library qube with sub-modules and facade

```
stdlib/math/
├── qube.json5
└── src/
    ├── lib.q
    ├── vec.q
    ├── mat.q
    ├── quat.q
    └── _scalar.q
```

```q64
// src/vec.q
//! q64.math.vec — Three-dimensional vector arithmetic.

import "./_scalar.q"

pub struct Vec3<T> { x: T, y: T, z: T }

pub fn dot<T>(a: Vec3<T>, b: Vec3<T>) -> T {
    a.x*b.x + a.y*b.y + a.z*b.z
}

fn normalize_in_place(v: ref Vec3<f32>) { ... }   // file-private
```

```q64
// src/lib.q
//! q64.math — Vectors, matrices, quaternions; dimensional units throughout.
//! exports: Vec3, Mat4, Quat, dot, cross, matmul, inverse, slerp

pub use Vec3, dot, cross from "./vec.q"
pub use Mat4, matmul, inverse from "./mat.q"
pub use Quat, slerp from "./quat.q"
```

### Three import styles from a consumer

```q64
// Namespace
import q64.math
let v: math.Vec3<f32> = ...
let d = math.dot(v, v)

// Selective
import q64.math.{Vec3, dot}
let v: Vec3<f32> = ...
let d = dot(v, v)

// Alias
import q64.math as m
let v: m.Vec3<f32> = ...
let d = m.dot(v, v)
```

### Folder sub-module with its own `lib.q`

```
my-qube/src/
├── lib.q
└── audio/
    ├── lib.q       → my_qube.audio
    └── filter.q    → my_qube.audio.filter
```

```q64
// my-qube/src/audio/lib.q
pub use Filter, lowpass, highpass from "./filter.q"
```

```q64
// Consumer (another qube)
import my_qube.audio.{Filter, lowpass}
```

## Grammar (informal)

```
ImportStmt   := "import" ImportPath ImportBinding?
ImportPath   := BareDotted | QuotedRelative
BareDotted   := Ident ( "." Ident )*
QuotedRelative := '"' RelPath '"'
ImportBinding  := SelectiveList | AliasBinding
SelectiveList  := "." "{" Ident ("," Ident)* "}"
AliasBinding   := "as" Ident

ReExport       := "pub" "use" SelectiveList "from" ImportPath
                | "pub" "use" Ident ("as" Ident)? "from" ImportPath

Item           := Visibility? (FnDecl | StructDecl | EnumDecl | TypeDecl | FaceDecl | FitDecl | ConstDecl | ActorDecl | EffectDecl | GraphDecl | ReExport)
Visibility     := "pub"
```

`ActorDecl` is specified in [`concurrency.md`](./concurrency.md)
§Grammar; `EffectDecl` (`pub effect @<name>`) is specified in
[`effects.md`](./effects.md) §"User-defined effects";
`GraphDecl` (`graph <name>(<params>) { … }`) is specified in
[`streams.md`](./streams.md) §"`graph` declaration". All follow
the same visibility model as other top-level items.

The block-`pub` form `Visibility "{" Item* "}"` is intentionally absent.

## Related specs

- [`qube.json5.md`](./qube.json5.md) — `dependencies` map drives bare-dotted
  module resolution.
- [`q64-cli.md`](./q64-cli.md) — `--module name=path` flag conveys
  resolved dependency directories to the compiler subprocess.
- [`diagnostics.md`](./diagnostics.md) — envelope format used for every
  `NAM*` error listed above.

## Open items deferred to future specs

- **Field visibility on structs** — pending the [faces/types spec](./faces.md).
- **Macros / comptime-generated modules** — pending the comptime spec.
- **Conditional compilation** (`@target("browser")` style) at the module
  level — pending the manifest's `targets` semantics being finalized.
- **Modules generated by `build.q`** — pending the build-escape-hatch spec.
