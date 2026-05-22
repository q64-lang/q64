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
| [`memory.md`](./memory.md)                               | Regions, dual heap, transfers, multi-memory layout, shared / managed annotations |
| [`concurrency.md`](./concurrency.md)                     | Scopes, tasks, channels, select, actors, cancellation, panics, host translation |
| [`streams.md`](./streams.md)                             | Signal / Event / Stream, @stage, graph, |>, pre(), fusion, SharedSignal          |
| [`env.md`](./env.md)                                     | Capability model, Env structure, main signature, with_capabilities, disclosure   |
| [`grammar.md`](./grammar.md)                             | Lexical structure and the consolidated syntactic grammar                          |
| [`tests/`](./tests)                                      | Conformance test corpus — `.q` source files paired with expected diagnostic envelopes. See [`tests/README.md`](./tests/README.md) for conventions and [`tests/INDEX.md`](./tests/INDEX.md) for code coverage. |

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
together. When in doubt, this table is authoritative:

| Word          | Meaning                                                                                            |
|---------------|----------------------------------------------------------------------------------------------------|
| **qube**      | The unit of distribution — a directory with a `qube.json5` at its root. What you publish, depend on, and import. |
| **qube** *(binary)* | The `qube` CLI tool — package and build operations. The repo glossary in [`../README.md`](../README.md) distinguishes the two by context. |
| **q64**       | The language. Also the name of the language CLI tool (`q64 build`, `q64 fmt`, `q64 lsp`).         |
| **continuum** | The registry — the q64 package hub. Hosted at `qubes.q64.dev`; the wire contract is [`continuum-api.md`](./continuum-api.md). |
| **face**      | A type-class-style interface (≈ trait / typeclass / protocol). See [`faces.md`](./faces.md).      |
| **fit**       | A binding of a type to a face (≈ impl). See [`faces.md`](./faces.md).                              |
| **region**    | An allocator with a lifetime. The single noun for memory ownership in q64. See [`memory.md`](./memory.md). |
| **region kind** | A concrete strategy backing a region: `Arena`, `Pool`, `Stack`, `FreeList`, `Managed`. The blessed inhabitants of the `Region` face. |
| **scope arena** | The implicit `Arena`-kind region bound to a `scope { … }` block, named `scope`. Where panic payloads and defaultable allocations land. See [`memory.md` §"Scope's implicit arena"](./memory.md). |
| **effect**    | A compile-time marker on a function (or stage, or face method) declaring what it touches or refuses. See [`effects.md`](./effects.md). |
| **stage**     | An `@stage`-annotated function — a node in a stream graph. See [`streams.md`](./streams.md).      |
| **diagnostic** | Any structured tool output — error, warning, note. The envelope is defined in [`diagnostics.md`](./diagnostics.md). |
| **trap**      | The bare Wasm "this module is no longer runnable" instruction. Distinct from `panic`. Used consistently across `errors.md`, `effects.md`, and `concurrency.md` — the word "halt" does not name a distinct concept in q64. |

## Why a spec at all

q64 has one implementation today and may always have one. The spec is not
written because of competing implementations — it is written because **the
compiler itself needs an answer key**. A formal spec catches the cases where
the implementation does something not-quite-right but technically consistent
within itself.
