# todo

Active work tracker. Things to do, things to decide, kept short and
ticked off as they land. Long-form design questions live in
[`docs/history/MIGRATION.md`](./docs/history/MIGRATION.md); this file is
for items the next session should be able to pick up and act on.

## C bindings

Two distinct questions, both currently "planned, not active."

### Compiler → C (Binaryen for Wasm codegen)

Documented in [`q64/src/codegen/README.md`](./q64/src/codegen/README.md)
and [`q64/vendor/README.md`](./q64/vendor/README.md). Today: zero C
deps pulled in; `q64/zig-out/bin/q64` is pure Zig (lex / parse / diag
only). Plan:

- [ ] Vendor Binaryen (`q64/vendor/binaryen/`, currently empty). Use
      `build.zig.zon` if upstream publishes a tarball; otherwise git
      submodule per `vendor/README.md`.
- [ ] Update `q64/build.zig` to link the Binaryen C library (`addCSourceFiles`
      or `linkSystemLibrary` with the vendored headers).
- [ ] Stub `q64/src/codegen/emit.zig` that opens the C API and produces
      an empty Wasm module. Validates the cross-compile story and gives
      codegen its first checkpoint.
- [ ] Wire `q64 emit <file>` into `src/main.zig` so we can dump the
      empty module from a parsed `.q` file.

Estimated effort: ~1 day for the stub; the real codegen lands later
production-by-production.

### User code → C (FFI from q64 programs)

Not specced. The corpus has no `extern "C"`, no `@cImport`-like form,
no `wasm-c-abi` discussion. Everything external goes through capability
faces in `env.md` plus the runtime adapters in `runtime/<host>/`.

This is a deliberate consequence of "the platform is Wasm 3.0" but
worth being explicit about. Decision needed:

- [ ] Write `spec/ffi.md` that either:
  - **(a)** commits to "no language-level FFI; everything goes through
    Wasm imports declared by runtime adapters and surfaced as capability
    faces" — close the gap by stating the rule, and document how
    a third-party C library reaches q64 today (compile to Wasm separately,
    add a runtime adapter that imports its exports, wrap as a face), or
  - **(b)** specifies a language-level FFI surface — `extern fn` on top
    of the Wasm component model, with effect markers / capability
    integration so the disclosure story keeps working.
- [ ] Update `runtime/*/README.md` to point at whichever decision lands.
- [ ] Cross-link from `env.md` so a reader who asks "how do I call this
      C library" has a documented answer.

(a) is the smaller spec; (b) is the larger commitment. Recommendation
is (a) for v0, with (b) deferred to a future revision once the
component-model story stabilizes upstream.

## Other open items

This section grows as we go. Each item should have a checkbox so it's
visible at a glance whether it's been picked up.

- [ ] Parser: items productions (`pub`, `fn`, `struct`, `enum`, `face`,
      `fit`, `import`). Unblocks NAM conformance tests.
- [ ] Parser: pattern + match arms. Unlocks half the remaining
      `spec/tests/` corpus.
- [ ] Parser: full expression precedence chain from `grammar.md`.
- [ ] `spec/annotations.md` — categorize `@`-forms (markers / derive /
      property wrappers). Smallest scope, highest cross-reference value.
- [ ] `spec/units.md` — drain the unit-suffix table out of `types.md`
      into a real lattice spec.
- [ ] `spec/test-framework.md` — `@test`, fixtures, the `Arbitrary` face
      surface. `env.md` and `spec/tests/` both use `@test` but it has no
      spec home.
- [ ] Pattern grammar completion — close the `(* open *)` markers in
      `grammar.md` §Patterns (guards, or-patterns, deep destructuring,
      range patterns, exhaustiveness).
- [ ] `docs/history/` cleanup — once `units.md`, `kinds.md`,
      `annotations.md`, `strings.md` land, the historical sources for
      them can be archived or deleted. Per MIGRATION.md's own plan.

## Conventions

- Tick `[x]` when done. Strike through and leave the line until the
  next sweep so we have a trail.
- Keep items terse — link to the spec / file / commit rather than
  re-explaining context here.
- New items append to "Other open items" by default; pull out into a
  named section when more than a few related items accumulate (as
  C bindings has).
