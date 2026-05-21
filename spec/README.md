# spec

The formal q64 language specification and conformance tests.

> **Status: not yet implemented.** The spec begins once the language is
> stable enough to be worth formalizing — likely after the first
> end-to-end compile works.

## Scope

- **Lexical structure** — tokens, literals, comments, identifier rules.
- **Syntax** — grammar in EBNF or equivalent.
- **Type system** — primitive types, region parameters, effect markers,
  generics, the full inference algorithm.
- **Memory model** — region kinds, dual heap, cross-heap rules, `@send`
  derivation, multi-memory layout.
- **Concurrency model** — scopes, tasks, channels, ordering guarantees,
  cancellation semantics.
- **Stream semantics** — synchronous-tick model, `pre` operator, graph
  scheduling, fusion rules.
- **Effect system** — the fixed set of markers, propagation rules,
  capability disclosure semantics.
- **Conformance test suite** — q64 source files plus expected outputs.
  Any future implementation passes these to claim conformance.

## Why a spec at all

q64 has one implementation today and may always have one. The spec is not
written because of competing implementations — it is written because **the
compiler itself needs an answer key**. A formal spec catches the cases where
the implementation does something not-quite-right but technically consistent
within itself.
