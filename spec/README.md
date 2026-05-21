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
| [`memory.md`](./memory.md)                               | Regions, dual heap, transfers, multi-memory layout, shared / managed annotations |
| [`concurrency.md`](./concurrency.md)                     | Scopes, tasks, channels, select, actors, cancellation, panics, host translation |

## Scope (forthcoming)

- **Lexical structure** — tokens, literals, comments, identifier rules.
- **Syntax** — grammar in EBNF or equivalent.
- **Type system inference algorithm** — the full bidirectional
  inference rules. (Primitive types and parameter modes landed in
  `types.md`; effect markers in `effects.md`; generics in
  `generics.md`.)
- **Stream semantics** — synchronous-tick model, `pre` operator, graph
  scheduling, fusion rules.
- **Conformance test suite** — q64 source files plus expected outputs.
  Any future implementation passes these to claim conformance.

## Why a spec at all

q64 has one implementation today and may always have one. The spec is not
written because of competing implementations — it is written because **the
compiler itself needs an answer key**. A formal spec catches the cases where
the implementation does something not-quite-right but technically consistent
within itself.
