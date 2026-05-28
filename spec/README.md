# spec

The formal q64 language specification, the public contracts every
toolchain component agrees on, and (eventually) the conformance test
suite.

> **Status: draft (v0).** The contracts that unblock parallel
> development are already written; the formal language semantics
> follow.

## Current contracts

| File                                                     | Covers                                                            |
|----------------------------------------------------------|-------------------------------------------------------------------|
| [`qube.json5.md`](./qube.json5.md) + `.schema.json`      | Manifest file every qube ships at its root                        |
| [`diagnostics.md`](./diagnostics.md) + `.schema.json`    | JSON envelope every toolchain binary emits on stderr              |
| [`q64-cli.md`](./q64-cli.md)                             | The `q64` binary's CLI surface and subprocess contract            |
| [`qube-cli.md`](./qube-cli.md)                           | The `qube` binary's CLI surface and how it invokes `q64`          |
| [`continuum-api.md`](./continuum-api.md)                 | HTTP API between `qube` and the registry                          |
| [`modules.md`](./modules.md)                             | Module organization, imports, visibility, re-exports              |
| [`faces.md`](./faces.md)                                 | Polymorphism: faces (interfaces) and fits (implementations)       |
| [`errors.md`](./errors.md)                               | `Result<T, E>`, `try`, `panic` / `trap`, `Option<T>`, `Error` face |
| [`effects.md`](./effects.md)                             | Effect markers, implication graph, propagation, capability disclosure |
| [`generics.md`](./generics.md)                           | Type / const / region / effect parameters, bounds, where, defaults, inference |
| [`types.md`](./types.md)                                 | Numeric tower, bool, arb-width ints, parameter modes, optional narrowing |
| [`units.md`](./units.md)                                 | Unit lattice: blessed unit types, prefixes, dimensional algebra, logarithmic units, `@unit` |
| [`annotations.md`](./annotations.md)                     | `@`-form catalog: four categories, casing rule, position table, `ANN` diagnostic band |
| [`test-framework.md`](./test-framework.md)               | `@test`, assertions, capability mocking, property tests, `Arbitrary` face, `TST` diagnostic band |
| [`memory.md`](./memory.md)                               | Regions, dual heap, transfers, multi-memory layout, shared / managed annotations |
| [`concurrency.md`](./concurrency.md)                     | Scopes, tasks, channels, select, actors, cancellation, panics, host translation |
| [`streams.md`](./streams.md)                             | Signal / Event / Stream, @stage, graph, |>, pre(), fusion, SharedSignal          |
| [`env.md`](./env.md)                                     | Capability model, Env structure, main signature, with_capabilities, disclosure   |
| [`grammar.md`](./grammar.md)                             | Lexical structure and the consolidated syntactic grammar                          |
| [`rpc.md`](./rpc.md)                                     | Qube-to-qube RPC over the synthesized WIT world: wRPC + component-value wire, the `@wire` effect, transports, addressing |
| [`tests/`](./tests)                                      | Conformance test corpus — `.q` source files paired with expected diagnostic envelopes. See [`tests/README.md`](./tests/README.md) for conventions and [`tests/INDEX.md`](./tests/INDEX.md) for code coverage. |

## Wasm 3.0 is the platform; the Component Model is an optional wrapper

Core Wasm 3.0 (the feature set committed in
[`memory.md` §"The platform"](./memory.md) — Memory64, multiple memories,
WasmGC, threads + atomics, stack-switching, SIMD) is q64's compilation
target and **primary artifact**. The default `qube build` produces a
**core module**.

WIT and the WebAssembly Component Model are **not** part of core Wasm 3.0
— they are a layered spec for host integration. q64 treats them as an
**opt-in wrapping layer**: a **component** embeds the unmodified core
module and adapts it to the canonical ABI, for hosts that speak components
(`wasmtime serve`, jco / componentize-js, wasmCloud). Emitting a component
does not change the language.

The component's import/export surface is **synthesized, not authored**: its
exports are the qube's public functions, and its imports are the qube's
compiler-derived capability set (per [`env.md`](./env.md) and
[`effects.md`](./effects.md)). The same synthesized `world` is the contract
for qube-to-qube **RPC** (see [`rpc.md`](./rpc.md)) — the canonical-ABI value
encoding doubles as the wire format.

q64 targets **WASIp3** (WASI 0.3) as its Component Model baseline. WASIp3 adds
native `stream<T>` / `future<T>` to the canonical ABI, so the `Signal` /
`Event` / `Stream` family **does** bridge to WIT — a `Stream<T, R>` lowers to
WIT `stream<T>` and a `Future<T>` to WIT `future<T>` at the component boundary
(see [`streams.md`](./streams.md) and [`env.md` §"Env and the Component Model
(WASI Preview 3)"](./env.md)). WASIp3 is at **release-candidate** status
upstream; q64 tracks it, pinned to the snapshot the active runtime implements
and re-pinned on each upstream RC release (see [`env.md`](./env.md)).

One abstraction is still deliberately **not** bridged to WIT: `faces` / `fits`
(a type-class system, not WIT `resource`s — see [`faces.md`](./faces.md)).
Sending WIT resources over the wire is also deferred, pending the separate
upstream resource-transfer story (not part of WASIp3 async).

## Scope (forthcoming)

- **Type system inference algorithm** — the full bidirectional
  inference rules. (Primitive types and parameter modes landed in
  `types.md`; effect markers in `effects.md`; generics in
  `generics.md`.)
- **Conformance test corpus expansion** — first batch of ~40 tests
  landed in [`tests/`](./tests); remaining coverage tracked in
  [`tests/INDEX.md`](./tests/INDEX.md) §"Next batches".

## Vocabulary

The spec is consistent about a handful of words that easily blur
together. When in doubt, this table is authoritative.

**Case carries meaning.** Brand names are Capitalized — **Q64**,
**Qube**, **Continuum** — and appear in headings, marketing, and
running prose. CLI commands are always monospace lowercase —
`q64`, `qube` — and only appear in code blocks, command examples,
and shell output. For the noun **qube** specifically, case is *also*
semantic: lowercase **qube** is a library; Capitalized **Qube** is a
deployable artifact (see [`qube.json5.md`](./qube.json5.md)'s
`type` field). Lowercase plural **qubes** is the generic term
covering both.

| Word          | Meaning                                                                                            |
|---------------|----------------------------------------------------------------------------------------------------|
| **qube**             | A library qube — `type: "library"`, exports a surface, no `main`. Linked into other qubes statically (dynamic linkage later). |
| **Qube**             | A deployment artifact qube — `type: "application"`, requires a `main`. The runnable unit. |
| **qubes** *(plural)* | The generic noun, covering both libraries and deployable artifacts. What you browse in the Continuum. |
| **`qube`** *(CLI)*   | The `qube` CLI tool — package and build operations against the manifest. |
| **Q64**              | The language. Also the brand wordmark for the product family. |
| **`q64`** *(CLI)*    | The language CLI tool (`q64 build`, `q64 fmt`, `q64 lsp`).         |
| **Continuum**        | The registry — where all qubes exist. UI at `continuum.q64.dev`; HTTP API at `qube.q64.dev`. Wire contract: [`continuum-api.md`](./continuum-api.md). |
| **face**      | A type-class-style polymorphism construct (≈ trait / typeclass / protocol). *Not* a WIT `interface` — see the `interface` row below and [`faces.md`](./faces.md). |
| **fit**       | A binding of a type to a face (≈ impl). See [`faces.md`](./faces.md).                              |
| **region**    | An allocator with a lifetime. The single noun for memory ownership in q64. See [`memory.md`](./memory.md). |
| **region kind** | A concrete strategy backing a region: `Arena`, `Pool`, `Stack`, `FreeList`, `Managed`. The blessed inhabitants of the `Region` face. |
| **scope arena** | The implicit `Arena`-kind region bound to a `scope { … }` block, named `scope`. Where panic payloads and defaultable allocations land. See [`memory.md` §"Scope's implicit arena"](./memory.md). |
| **effect**    | A compile-time marker on a function (or stage, or face method) declaring what it touches or refuses. See [`effects.md`](./effects.md). |
| **stage**     | An `@stage`-annotated function — a node in a stream graph. See [`streams.md`](./streams.md).      |
| **diagnostic** | Any structured tool output — error, warning, note. The envelope is defined in [`diagnostics.md`](./diagnostics.md). |
| **trap**      | The bare Wasm "this module is no longer runnable" instruction. Distinct from `panic`. Used consistently across `errors.md`, `effects.md`, and `concurrency.md` — the word "halt" does not name a distinct concept in q64. |
| **module**    | A q64 **source** namespace — the unit of `import` / visibility / re-export inside a qube. See [`modules.md`](./modules.md). Never the Wasm artifact; that is a **core module**. |
| **core module** | The primary Wasm 3.0 artifact `q64 emit` produces. The default `qube build` output. Distinct from a q64 source `module` and from a `component`. |
| **component** | The opt-in WebAssembly Component Model wrapper around the core module (Component Model + WIT, *not* part of core Wasm 3.0). Emitted only when asked; embeds the unmodified core module. See [`modules.md` §"The qube as a component"](./modules.md). |
| **world**     | The WIT `world` synthesized from a qube's public surface — its component exports (public functions) and imports (derived capability set). Authored by no one; generated. Also the RPC contract (see [`rpc.md`](./rpc.md)). |
| **interface** | The **WIT** sense: a named group of functions / types / resources in a `world`. Reserved for this meaning in the spec. q64's type-class abstraction is a **`face`**, never called an "interface" unqualified. |
| **resource**  | A WIT handle to host- or instance-local state (e.g. an open file). Adapter-internal: q64 user code never holds one, and resources are **not** surfaced as faces/fits, nor sent over RPC. |

## Why a spec at all

q64 has one implementation today and may always have one. The spec is not
written because of competing implementations — it is written because **the
compiler itself needs an answer key**. A formal spec catches the cases where
the implementation does something not-quite-right but technically consistent
within itself.
