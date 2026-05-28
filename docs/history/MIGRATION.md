# Migration TODO

This repo (`q64-lang/design`) is being **superseded by the formal spec
corpus at `q64-lang/q64/spec/`**. Material lands in this repo first
(loose, discussion-shaped), then graduates to a spec once the
decisions are settled. When everything that matters from here has a
spec home, this repo will be archived.

This file is the running map of what's done, what's missing, and what
still needs design work before it can become a spec.

## Current state

| | Repo | What's in it |
|---|---|---|
| ✅ | `q64-lang/q64/spec/` | The authoritative specs (see list below) |
| ⚠️ | `q64-lang/design/` | This repo — design discussion; will be archived |
| ✅ | `q64-lang/q64/` | Monorepo with `continuum/`, `docs/`, `examples/`, `mcp/`, `q64/`, `qube/`, `runtime/`, `spec/`, `stdlib/`, `web/` |

### Specs already landed in `q64-lang/q64/spec/`

| File | Covers |
|---|---|
| `qube.json5.md` + `.schema.json` | The manifest format every qube ships at its root |
| `diagnostics.md` + `.schema.json` | JSON envelope every toolchain binary emits on stderr |
| `q64-cli.md` | The `q64` binary surface and subprocess contract |
| `qube-cli.md` | The `qube` binary surface and how it invokes `q64` |
| `continuum-api.md` | HTTP API between `qube` and the registry |
| `modules.md` | Module organization, imports, visibility, re-exports |
| `faces.md` | Polymorphism — `face` (interface) and `fit` (implementation) |
| `errors.md` | `Result<T, E>`, `try`, `panic`/`trap`, `Option<T>`, `Error` face |
| `effects.md` | Effect markers, implication graph, propagation, capability disclosure |
| `generics.md` | Type / const / region / effect params, bounds, where, defaults, inference |
| `types.md` | Numeric tower, bool, arb-width ints, parameter modes, optional narrowing |

Vocabulary established and used consistently across all of the above:
- **qube** = unit of distribution; described by `qube.json5`
- **continuum** = the registry that stores qubes
- **q64** = the language binary (single-file ops, fmt, lsp, show, explain)
- **qube** *(binary)* = the project/build tool (new, add, build, test, publish, fix, explain)
- **face / fit** = q64's nominal polymorphism — faces declare contracts, fits bind types
- **`try` / `panic` / `trap`** = error propagation, structured abort, bare wasm trap

Syntax decisions locked:
- Generic brackets: `<>` (Swift-style, no dot, no turbofish). Parser handles `<>` vs comparison via context-sensitive lookahead.
- Return type: `->` (Swift-style)
- Bound separator: `:` (in fits, in generic bounds)
- Fit syntax: `fit Type : Face<Aux?>` for single-param faces; `fit Face<T1, T2>` for multi-param faces (asymmetric; the compiler enforces from the face declaration)

## Material in this repo that still needs a spec home

In rough order of payoff per page of spec.

### Priority 1 — small, well-bounded, unblocks other specs

**`spec/effects.md`** ✅ landed — the formal effect-marker registry.
Nine markers, implication graph, propagation, opaque user-defined
effects, `@send` derivation, capability disclosure to the registry,
`EFF104`–`EFF151`.

**`spec/generics.md`** ✅ landed — graduated from faces.md alongside
effects. Four parameter kinds (type / const / region / effect),
explicit `const` for value params, `where` after the signature,
defaults, aggressive inference, `TYP100`–`TYP112` + `PAR040`.

**`spec/types.md`** ✅ landed — the type-system core surface.
Numeric tower (no usize), arb-width ints with auto-widen
arithmetic, strict no-implicit-promotion (departs from the
Julia-influenced note in design.md), parameter modes at signature
only (bare call sites; departs from design.md's repeated-keyword
sketch), syntactic optional narrowing, SIMD / Tensor / DynTensor
as builtins, little-endian as a language fact. `TYP040`–`TYP090`.

### Priority 2 — q64's signature feature

**`spec/streams.md`** ✅ landed — q64's most distinctive feature,
now spec'd. Ten open design calls resolved. Departs from this
repo's narrative on several points:

- Sample rate is a **type parameter** on Signal<T, R> and
  Stream<T, R>, not implicit. Cross-rate mixing requires explicit
  resample (STR021). The narrative was rate-agnostic.
- `@stage` is an annotation on `fn`, not a `stage` keyword.
  Consistent with @shared / @managed / @derive elsewhere.
- `pre()` is a method on Signal / Stream, not a prefix operator.
  Reads as ordinary method dispatch.
- Cross-thread signals get a distinct type `SharedSignal<T, R>`
  in `mem.shared`, not the sample→channel→hold pattern the
  narrative described. Latency: one tick + one atomic op
  (vs tens of ms for sample→channel→hold), at the cost of one
  explicit distinct type.
- Fusion is **opt-in via @fuse**, not automatic. The user marks
  which stages may be merged into one task. Makes task boundaries
  explicit and predictable.
- Errors **panic** and propagate via concurrency.md's
  `scope { … } catch (e: Panic) { … }`; no second error mechanism
  at the stream layer.

Locks in: three distinct dataflow types (Signal continuous,
Event discrete, Stream completes); `graph` keyword for named
topologies; |> as F#/Elixir first-argument pipe; four canonical
conversions (changes / hold / fold / sample) — combinators live
in q64.streams library; rate-polymorphic stages via
`fn gain<const R: Hz>`; effect propagation across |> with
STR060 for @realtime/non-realtime mixing; stage→task and
|>→channel desugaring contracts with concurrency.md.

`STR010`-`STR063` diagnostic band.

### Priority 3 — port directly from existing design docs

**`spec/memory.md`** ✅ landed — ported and tightened. Departs from
this repo's narrative on three points:

- `region rt: Arena<1.MB> { … }` block-statement form (was
  `Arena.scope { … }`-ish in memory.md).
- `@shared struct …` and `@managed struct …` annotations replace
  the `shared_region { … }` and `managed struct …` keyword forms
  sketched in memory.md and design.md. Annotation pattern matches
  `@derive` and other declaration-level annotations elsewhere in
  q64.
- A single generic `value.transfer(to: target)` verb replaces the
  three named ops `copy_to / pin_to / intern`. Source + target
  kinds drive semantics; no aliases at the surface (`REG050`).
- `Interned<R>` is a transfer-target marker composing over a
  backing region, not its own region kind.

Locks in: scope's implicit `scope` arena; six fixed Wasm linear
memories (`mem.stack / mem.arena / mem.heap / mem.shared /
mem.large / mem.rodata`); `Atomic<T>` capitalized (consistent with
`Vec<T>` / `Box<T>`); four `Shared<T, P>` policies (Mutex / RwLock
/ LockFree / Disjoint<F>); FreeList-exit-with-live-allocs raises
`REG040`; `@realtime` hard-bans `transfer` via `EFF110`.

`REG010`-`REG050` diagnostic band.

**`spec/concurrency.md`** ✅ landed — ported and tightened.
Departs from this repo's narrative on several points:

- Cancellation: explicit `ctx: Cancel` parameter, Go-style. The
  narrative left observation underspecified ("a task observes
  `ctx.cancelled()` at suspension points or in long loops"); the
  spec pins down that `ctx` is a real parameter, not ambient.
- Actor reply: `tell` vs `ask` (two verbs split by reply-or-not),
  not a single `c.send(Msg)` returning unit-or-future.
  Cross-use is a compile error.
- Handle ownership: drop a `Handle` = cancel + join. Diverges
  from Swift TaskGroup / Trio "auto-join unawaited handles."
- `select` cancellation: implicit `ctx.cancelled()` branch on
  every `select`; user can override for cleanup.
- Channel construction: lowercase `channel<T>(…)` factory (the
  square-bracket form here migrates to angle brackets per
  generics.md's lock).
- Channel default: **no** default policy; `CONC050` if a
  `channel<T>(…)` omits `policy:`. Every channel construction
  states its bounded / overwriting / blocking choice.
- Panic handling: `scope { … } catch (e: Panic) { … }` block.
  Cancellation of siblings happens either way; `catch` runs
  after all children finish.
- Task arena: tasks share the enclosing scope's implicit arena
  with a per-allocation mutex (not per-task arenas).

Also formalizes: `Atomic<T>` / `Shared<T, P>` references go
through memory.md; `@shared struct …` annotation replaces the
`shared_region world { … }` block sketched here; new effect
markers `@cancel` and `@uncancellable` tracked in concurrency.md
(effects.md will absorb the formal definitions in a follow-up).

`CONC010`-`CONC052` diagnostic band.

### Priority 4 — fill in the capability surface

**`spec/env.md`** ✅ landed — the capability model. Six open
design calls resolved. Notable points:

- `Env` is a hierarchical struct with typed sub-capability
  fields (out / err / exit / args / envvars / time / random /
  net / fs / audio / midi / ai / ui). Higher-layer caps (gfx,
  video, gpu, nn) live in user qubes / stdlib packages.
- Capabilities are **faces**, not sealed types. Runtime provides
  one fit per face; tests + libraries can fit their own
  (`fit MockNet : Net`).
- **Ambient `env` binding (v0 redesign).** Functions reference
  `env.X` directly without declaring it as a parameter; the
  compiler synthesizes an implicit capability parameter per
  reference, the same machinery as `generics.md`'s implicit
  face parameters. The earlier "passed, not ambient" model
  with smallest-capability lint `ENV010` is superseded.
  Explicit `pub fn helper(n: Net, …)` remains a valid power-
  user form for parametric library code.
- Sandboxing via `with_capabilities { … }` block — now the
  primary override mechanism, with two flavors: `use: { net:
  MockNet.new() }` substitutes a fit (compile-time-resolved),
  `deny: [Net, Fs]` strips capabilities (runtime-enforced;
  `ENV030` panics on attempted use). Both compose.
- Four valid `main` signatures: `fn main`, `fn main -> Result<(),
  Error>`, and the explicit `fn main(env: Env)` / `fn main(env:
  Env) -> Result<(), Error>` forms. Runtime dispatches on
  presence and return type.
- Capability disclosure is **both** manifest-asserted in
  `qube.json5` **and** compiler-derived from the effect graph
  (@network → Net, @fs → Fs, …). `qube publish` cross-checks;
  mismatch is ENV040. Lock-file pattern: intent + verification.

`ENV010` / `ENV011` retired by the redesign; the rest of the
`ENV020`-`ENV056` diagnostic band stays. New: `ENV055` (`use:`
field not on `Env`), `ENV056` (`env` reference from `@pure`
function).

Introduces a `capabilities` field in `qube.json5`. The qube.json5
spec will need a matching section update — tracked as a follow-up.

**Cross-spec sweep needed (post-redesign):** The illustrative
examples in `errors.md`, `concurrency.md`, `streams.md`,
`faces.md`, `effects.md`, `memory.md`, plus the golden tests in
`spec/tests/golden/`, currently thread `env: Env` through library-
style helpers — a pattern the redesign deprecates. The substantive
content of those specs is unaffected; only the example shape
needs updating. Tracked as a single follow-up pass.

### Priority 5 — short follow-up specs

**`spec/units.md`** — units of measure (Hz, Db, Semitones, …).
Dimensional algebra, conversion rules, literal syntax (`48.kHz`,
`-6.dB`). Source: `design.md` §"Units as types"; `example.md` §Units.

**`spec/kinds.md`** — the `@kind` family of zero-cost semantic newtypes.
Source: `example.md` §Kinds. Used for PCM / Colors / Video frames /
AI tokens.

**`spec/annotations.md`** — the three categories of `@`-annotation.
Source: `design.md` §Annotations.
- Compiler-known markers (lowercase): `@realtime`, `@pure`, `@inline`,
  `@deprecated`, `@public`, `@test`.
- Derive (`@derive(Json, Hash, Debug)`).
- Property wrappers (PascalCase): `@Signal`, `@Event`, `@Stream`,
  `@Atomic`, `@Lazy`.

**`spec/strings.md`** *(optional)* — string-literal forms (`"..."`,
`url"..."`, multi-line, raw, interpolation with `{expr}`). Could fold
into `spec/types.md`.

## Material that still needs *new* design work

These are open questions in `design.md` §"Open Questions" or items
deferred from current specs. Spec writing can't start until each gets
its discussion turn:

| Topic | Notes |
|---|---|
| Pattern matching grammar | Used informally in `faces.md`, `errors.md`. Needs full grammar: guards, or-patterns, struct destructuring, exhaustiveness. |
| Pipe operator `|>` syntax + semantics | Central to streams. F#/Elixir-flavored. Forwards rather than composes. |
| Stage / graph DSL | The result-builder syntax for stream graphs. Swift-influenced. |
| Region parameters concrete syntax in fn signatures | `faces.md` uses it; full grammar (defaults, elision rules) not pinned. |
| Comptime semantics | What runs when, hygiene, scope. Unblocks `@derive`. |
| Test framework | `@test`, fixtures, property-test integration with `face` laws, `Arbitrary` face surface. |
| Actor sugar — full surface | Reply channels, supervision, restart strategies, generic actors. `concurrency.md` sketches the happy path only. |
| Operator overloading rules | Arithmetic on units (`Hz + Hz`, `Hz * Seconds = scalar`). |
| Hot reload protocol | Open. |
| Plugin system for build-time extensions | Open. |
| JS interop ABI | `runtime/browser/` scoped; full ABI not specified. |
| WASI integration strategy | `qube.json5` targets select preview1/preview2/wasix; deeper integration open. |
| Debugging story | Source maps, debug info; partial LSP coverage in `q64-cli.md`. |
| Field visibility on structs | Deferred from `modules.md` and `faces.md`. Lives with a future types/struct spec. |
| `Arbitrary` face surface | Deferred from `faces.md` §Laws. |
| Specialization of default methods | Deferred from `faces.md`. |
| Const-evaluated bounds | Pending comptime. |
| `dyn`-safety predicate | The exact rules; deferred from `faces.md`. |
| Automatic `From` derivation between sub-enums | Repetitive without it; future revision. |
| Stack traces in `panic` | Currently message-only; opt-in trace capture is open. |

## Material that's reference / historical

Does not need to migrate to a spec. Keep here, or move to a
`q64-lang/q64/docs/history/` folder before this repo is archived.

- `influences.md` — full lineage rationale (Rust, Swift, C#, Zig, F#,
  Julia, Lustre, Hylo, Elixir/Erlang, structured-concurrency lineage,
  notable absences).
- `design.md` §"The Bet" — narrative framing of the five committing
  decisions.
- `design.md` §"Design Principles" — the eight recurring principles.
- `design.md` §"Syntax Lineage" — short version of `influences.md`.

## Suggested order of work

For a fresh context picking this up:

1. Read this file plus `q64-lang/q64/spec/README.md`.
2. Read every spec in `q64-lang/q64/spec/` in this order:
   `modules.md` → `faces.md` → `errors.md` → `qube.json5.md` →
   `diagnostics.md` → `q64-cli.md` → `qube-cli.md` →
   `continuum-api.md`.
3. Cold-read those for any "wait, what?" moments — flag and revisit.
   Particularly:
   - **`face Eq<T>` vs `face Buffer<T>`** — different roles for `T` in
     each case. Self is implicit in `Buffer`-shape (methods use
     `self`); `T` is the receiver in `Eq`-shape (methods don't use
     `self`). Worth either formalizing or simplifying.
   - **Path A asymmetry on multi-param fits** — `fit Convert<Rgb, Hex>`
     reads face-first while `fit Color : Display` reads
     implementer-first. Path B (tuple form, `fit (Rgb, Hex) : Convert`)
     was discussed; deferred.
4. Priority 1 complete. `effects.md`, `generics.md`, and
   `types.md` have all landed.
5. Next is the Priority-3 port: `memory.md` and `concurrency.md`
   straight across, then Priority-2 (`streams.md`, the big one).
   This ordering pins regions + tasks + channels before streams
   composes them.
6. Once Priority-1 through Priority-4 are in spec, this design repo
   becomes redundant. Archive it.

## Conventions to follow

When writing new specs:
- File goes in `q64-lang/q64/spec/<name>.md`.
- One commit per spec.
- Push to both `main` and `claude/read-both-repos-ftoJ4` on
  `q64-lang/q64`.
- Use `<>` for generics (no dot), `->` for return types, `:` for
  bounds + fits.
- Number new diagnostic codes in their subsystem's prefix (e.g., new
  type errors as `TYP3xx` / `TYP4xx`; new effect errors as `EFF1xx`),
  never reuse a number, gaps are fine.
- Cross-link to other specs liberally.
- End each spec with an "Open items deferred" section so it's clear
  what didn't get nailed down.

## Pointers

- Monorepo: <https://github.com/q64-lang/q64>
- Design (this repo): <https://github.com/q64-lang/design>
- Plan file for the current session lived at
  `/root/.claude/plans/we-now-turn-q64-lucky-minsky.md`; the running
  decision log was kept there until plan mode exited.
