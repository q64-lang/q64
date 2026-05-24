# todo

Active work tracker. Things to do, things to decide, kept short and
ticked off as they land. Long-form design questions live in
[`docs/history/MIGRATION.md`](./docs/history/MIGRATION.md); this file is
for items the next session should be able to pick up and act on.

## Compiler + linking — ACTIVE FOCUS (resuming after the weekend)

The registry and the package up/download loop are **done and live**. The
definition of done — `dev.q64.hello_app` prints `0.1.0` by calling
`dev.q64.hello_world.version()` — is **met** for the const-foldable case via
the linking ladder below. The test pair now lives in the repo at
`examples/link-demo/` (no longer ephemeral in `/tmp`).

Verify (builds q64 + host + qube, then exercises both `q64 emit --module`
and `qube run`):

```
./scripts/link-roundtrip.sh           # → PASS: 0.1.0
```

### Done this session (for the trail)
- [x] Registry: JSON5 manifest-read fix + publish-time name validation, deployed
      to `qubes.q64.dev` (`continuum-api/src/routes/qubes.ts`).
- [x] Naming → reverse-DNS dotted snake_case (`dev.q64.webmcp_client`); name =
      module path = URL segment, no transforms; `q64.*` reserved for stdlib.
      Specced across `qube.json5.md`/`.schema.json`, `modules.md`,
      `continuum-api.md`, `q64-cli.md`, `qube-cli.md`.
- [x] `qube login` / `publish` / `add` implemented (`qube/src/main.zig`) and
      tested live: publish packs+uploads; add resolves → downloads → SHA-256
      verifies → extracts to `~/.qube/cache/sha256/<ab>/<cd>/<digest>/` → edits
      the manifest's `dependencies`.
- [x] Test pair built: `dev.q64.hello_world` (published, live) + `dev.q64.hello_app`.

### The linking ladder (do in order)
0. [x] **DO FIRST.** `q64 emit` now **errors** on constructs it can't compile
       instead of silently embedding them — string interpolation whose value
       isn't a compile-time constant (`UnsupportedInterpolation` /
       `NotConstExpr`) and imports it can't resolve (`UnknownModule` /
       `NameNotFound` / `UnsupportedImport`). `q64/src/codegen/emit.zig`
       `Resolver` + `renderStringLit`; `cmdEmit` reports + exits non-zero.
1. [x] JSON5 manifest parsing in `qube run`/`web` (`qube/src/main.zig`
       `json5ToJson` strips `//`+`/* */` comments and trailing commas, then
       parses with `std.json` into a `Value`). Single-quoted strings /
       unquoted keys not yet handled (no manifest in the corpus uses them).
2. [x] `--module <name>=<dir>` flag in `q64` (`q64/src/main.zig` `cmdEmit`),
       repeatable. Reads each module's `src/lib.q` and hands codegen a
       `[]ModuleSource`. Spec: `q64-cli.md:71`.
3. [x] Import resolution in codegen (`q64/src/codegen/emit.zig` `Resolver`):
       resolves `import dev.q64.hello_world.{version}` via the `--module`
       map. Bare-dotted selective imports only for now; relative + stdlib
       imports error (`UnsupportedImport`).
4. [x] `qube run`/`web` pass `--module` per dependency (`resolveModuleSpecs`
       maps each `path` dependency → `<dep>/src` absolute). Local-path deps
       only; a registry/git dep is reported and rejected (wants the
       `qube.lock` + cache resolution below).
5. [~] Cross-module calls land via **compile-time const-folding**: an imported
       function whose body is a constant (`fn version() -> str { "0.1.0" }`) is
       evaluated and its value spliced in. Enough for the DoD. Real wasm
       emission of callee functions + a string return ABI is the follow-up
       (needs the deeper parser/typeck work below).
6. [x] Codegen: string interpolation `"{expr}"` — `{expr}` is parsed (via
       `parse.parseExpression`), const-evaluated, and concatenated; `{{`/`}}`
       are literal braces. Runtime-valued interpolations error honestly.

**Definition of done met.** `cd examples/link-demo/hello_app && qube run`
prints `0.1.0` by linking `dev.q64.hello_world` (a local-path dependency)
and calling its `version()`. Durable regression test:
`scripts/link-roundtrip.sh` (covers `q64 emit --module` *and* `qube run`) +
`examples/link-demo/`.

Long pole still ahead: a real (non-const-folded) cross-module call needs the
open parser productions below — codegen can't walk what the parser doesn't
produce. That parser work is the real critical path.

### Deferred package bits (not compiler; pick up anytime)
- [ ] `qube.lock` — `add` doesn't write one; needed for ladder step 4.
- [ ] `add` dedup + `--offline` / `--frozen` / `--locked` flags.
- [ ] `qube publish` clean-release-build check (`qube-cli.md` publish step 4) — blocked on compiler.
- [ ] `qube remove` / `install` / `outdated` still stubs.

### Notes for the next agent
- Build with the **vendored** zig: `vendor/zig/zig build` (homebrew zig at
  `/opt/homebrew/bin/zig` has different `std.Io` APIs). The login command had
  stale `takeDelimiterExclusive`/`readAllAlloc` calls fixed this session to
  match the pinned zig — watch for the same drift elsewhere.
- Deploy the registry: `cd continuum-api && CLOUDFLARE_ACCOUNT_ID=*** pnpm run deploy` (needs `wrangler login`, account ***).
- Registry auth is the dev bypass `***` / `***` (`continuum-api/src/routes/auth.ts`, flagged for deletion when OAuth lands).

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

## Host ABI for non-trivial faces — discussion phase

`env.out`'s `(ptr: i32, len: i32) -> ()` works for "bytes to stdout"
because the host knows the bytes are UTF-8 and that's it. Real faces
have structure — `env.audio` enumerates devices, reports
AudioWorklet status, hands off streaming buffers, takes callbacks
back into the module at audio-thread rate. None of that fits a raw
ptr+len convention.

We need to pick **one** "fixed form" for typed faces before more
stdlib code accretes. Options, ranked by how much new toolchain we
take on:

1. **Hand-specced per-face ABI in `spec/<face>.md`.** Memory layouts
   for records (`{id, name, channels, sample_rate}`), return-via-
   out-ptr conventions, error tag bytes, callback function-table
   slots. Host code (`runtime/wasmtime/`, `runtime/browser/`,
   `runtime/audio-host/`) implements decoders against the spec.
   Cheapest now; brittle as faces multiply.
2. **WIT / Component Model for non-trivial faces.** Keep `(ptr,len)`
   for `env.out`-class trivia; spec `Audio`, `Net`, `Fs` in WIT and
   lower through the component model. Standard-flavored, generated
   host bindings, but commits us to CM tooling and the runtime
   adapters grow a CM layer.
3. **Wasm GC reference types.** Pass typed `struct` / `array` refs
   across the import; no marshaling. q64 already targets Wasm 3.0,
   but Binaryen's GC support for generated modules isn't mature
   enough today.

JS-side: regardless of which path, the browser host (`runtime/browser/`)
needs a glue ESM that users drop into their site — `import { runQ64 }
from 'q64-browser-host'` style. The shape of that module depends on
which option above we pick; (1) means hand-written decoders per face,
(2) means generated bindings, (3) means very thin glue + Wasm GC
interop.

- [ ] Decide between (1) / (2) / (3). Probably (1) for v0 with a
      clear migration path to (2). Capture the decision in
      `spec/faces.md` and link from `spec/audio.md` when that lands.
- [ ] Spec the audio face wire format as the first concrete
      instance — drives the abstraction by example.
- [ ] Sketch the browser-host JS glue API (`runQ64`, capability
      injection, AudioWorklet bridge) so the debug page in
      [qube web] can render it.
- [ ] Cross-link from `env.md` and each face's spec.

## Other open items

This section grows as we go. Each item should have a checkbox so it's
visible at a glance whether it's been picked up.

- [x] Parser-emitted syntactic NAM diagnostics: `NAM003` (wildcard import),
      `NAM004` (selective+alias), `NAM009` (block `pub`), `NAM011` (dash in
      bare path). Conformance 6→10. The semantic NAM codes (`NAM001/002/005…`,
      need a name-resolution pass) and `LEX020/021`, `PAR040` remain.
- [x] Parser: items productions. `fn`, `import`, `struct`, `enum`, `type`,
      `const`, `face`, `fit` all parse now (shared `pub` prefix +
      `itemKeyword` dispatch). Struct record fields and enum variants are
      structured; field/variant *types*, generic-param internals, and
      face/fit method bodies are still raw token spans (pending the
      type-expression grammar). New item nodes aren't surfaced through
      `ast.Item` yet (only `FnDecl`), so codegen is unaffected. Real
      `dev.q64.webmcp_client` library files now parse with no diagnostics.
- [x] Parser: full expression precedence chain (binary/unary/try/postfix)
      from `grammar.md`. `parseBinExpr` (precedence climbing) over
      `parseUnary`→`parseTryExpr`→`parsePostfix`→`parsePrimary`; postfix
      call/index/field/method/tuple-field/`?.`; paren/tuple/array primaries.
      Dotted paths stay one greedy `PATH_EXPR` so `env.out(…)` keeps its
      `CALL_EXPR[PATH_EXPR, CALL_ARGS]` shape (codegen unchanged).
      **`PAR040` was attempted here but reverted**: telling a generic call
      (`PCM<f32>(0.0)`) from a chained comparison (`a < b > c`) needs name
      resolution — a pure-syntax heuristic false-positives on valid
      generics. PAR040 is therefore deferred to the name-resolution pass.
- [ ] AST views: extend `q64/src/parser/ast.zig` as each item
      production lands (`StructDecl`, `EnumDecl`, `FaceDecl`, …). `FnDecl`
      and `ImportStmt` seeded the pattern.
- [x] Parser: statement productions inside `Block`. `let`/`var`,
      `return`/`break`/`continue`, `panic`, `if`/`else` (+ `if let`),
      `while`, `loop`, `for`, `match` (+ arms), and assignment vs
      expression statements all structure now (`parseStmt` dispatch).
      Only `EXPR_STMT` is surfaced to `ast.Stmt`, so codegen is
      unaffected. Still raw spans: let-bindings, for/match patterns,
      and types (pending the pattern grammar). Not yet structured:
      `scope`/`select`/`region`/`with_capabilities`/item-`const` (fall
      to the lossless expr/assign fallback).
- [x] Runtime: wasmtime host that runs `hello.wat` and prints
      "Hello, q64.\n" via the `env.out` import
      (runtime/wasmtime/src/main.zig). v0 byte-level golden for
      codegen.
- [x] Codegen: vendor Binaryen + `q64/src/codegen/emit.zig` with
      `emitHelloWasm()` that builds the hello module via the
      Binaryen C API. End-to-end roundtrip via
      `scripts/hello-roundtrip.sh`.
- [x] Codegen: graduate `emit.zig` from a hardcoded hello fixture
      to walking an `ast.FnDecl`. `emit.emitFromSource` parses a
      source file, walks `fn main`'s body, and emits a wasm module
      with N `env.out("…")` calls laid out in linear memory.
      `examples/hello/hello.q` + `scripts/hello-roundtrip.sh`
      exercise the full parse → AST → codegen → runtime chain.
- [x] Parser: pattern grammar (v0 floor). `parsePattern` covers wild /
      literal / ident / tuple / tuple-struct / record-struct / enum-variant,
      wired into `match` arms, `let`/`var`, `for` heads, and `if let`.
      Guards / or-patterns / ranges / deep destructuring still deferred
      (see "Pattern grammar completion" below). The real
      `dev.q64.webmcp_client` example app (match on strings + variants,
      `for`, raw strings, interpolation) now parses with no diagnostics.
- [x] Parser: lexer raw strings `r"…"` / `r#"…"#` (STR_RAW).
- [ ] Parser: record/struct **expression** literals (`Point { x: 1 }`,
      `DemoTools {}`) in expression position. Deferred for the
      struct-literal-vs-block ambiguity (Rust-style); today they degrade to
      lossless one-token recovery. Needs the disambiguation rule (likely:
      no bare record literal in `if`/`while`/`match` scrutinee position).
- [x] `spec/annotations.md` — categorize `@`-forms (markers / derive /
      property wrappers). Smallest scope, highest cross-reference value.
- [x] `spec/units.md` — drain the unit-suffix table out of `types.md`
      into a real lattice spec.
- [x] `spec/test-framework.md` — `@test`, fixtures, the `Arbitrary` face
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
