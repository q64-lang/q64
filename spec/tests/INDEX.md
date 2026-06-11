# Test index

Mapping from diagnostic code to conformance test. Maintained by hand
when tests are added or a code's owning spec moves. The table is the
audit surface — `grep ' — $' INDEX.md` lists every code that still has
no test.

> **Coverage today: 39 / ~155 named codes (≈25%) + 5 golden positives.**
> Coverage will grow as the implementation surfaces corner cases; new
> tests are appended to their subdirectory and the matching row updated
> here.

## Conventions

- Each row names a code, its owning spec, a one-line summary, and the
  test path (relative to `spec/tests/`). `—` means no test yet.
- A code with more than one test (the same code fires from multiple
  surface forms) lists each path separated by `, `.
- Golden positive tests are not indexed by code; they appear in §Golden.

## Lexical — `LEX*`

| Code     | Owner           | Short message                                     | Test                                                     |
|----------|-----------------|---------------------------------------------------|----------------------------------------------------------|
| `LEX010` | grammar.md      | stray carriage return                             | `lexical/stray-carriage-return.q`                        |
| `LEX011`–`LEX019` | (reserved) | —                                                | —                                                        |
| `LEX020` | types.md        | unknown string-literal prefix                     | `lexical/string-typed-prefix-unknown.q`                  |
| `LEX021` | types.md        | unexpected `&` in type position                   | `lexical/ampersand-in-type.q`                            |

## Parser — `PAR*`

| Code     | Owner           | Short message                                     | Test                                                     |
|----------|-----------------|---------------------------------------------------|----------------------------------------------------------|
| `PAR040` | generics.md     | generic vs less-than ambiguity                    | `parser/generic-vs-less-than.q`                          |

## Modules and names — `NAM*`

| Code     | Owner           | Short message                                     | Test                                                     |
|----------|-----------------|---------------------------------------------------|----------------------------------------------------------|
| `NAM001` | modules.md      | unknown module                                    | —                                                        |
| `NAM002` | modules.md      | import path escapes qube                          | `modules/import-path-escapes-qube.q`                     |
| `NAM003` | modules.md      | wildcard import is forbidden                      | `modules/wildcard-import.q`                              |
| `NAM004` | modules.md      | selective import combined with alias              | `modules/selective-with-alias.q`                         |
| `NAM005` | modules.md      | name collision in import scope                    | `modules/import-collision.q`                             |
| `NAM006` | modules.md      | name is private to its qube                       | —                                                        |
| `NAM007` | modules.md      | sub-module not re-exported                        | —                                                        |
| `NAM008` | modules.md      | re-export cycle                                   | —                                                        |
| `NAM009` | modules.md      | block `pub` form is forbidden                     | `modules/block-pub-form.q`                               |
| `NAM010` | modules.md      | unknown name in source module                     | —                                                        |
| `NAM011` | modules.md      | dash in bare module path                          | `modules/dash-in-bare-path.q`                            |

## Types — `TYP040`–`TYP099`

| Code     | Owner           | Short message                                     | Test                                                     |
|----------|-----------------|---------------------------------------------------|----------------------------------------------------------|
| `TYP040` | types.md        | integer literal out of range                      | `types/int-literal-out-of-range.q`                       |
| `TYP041` | types.md        | numeric type mismatch                             | —                                                        |
| `TYP042` | types.md        | implicit numeric conversion is forbidden          | `types/numeric-mismatch-no-implicit.q`                   |
| `TYP043` | types.md        | narrowing cast may overflow                       | —                                                        |
| `TYP044` | types.md        | wrong mode for argument                           | —                                                        |
| `TYP045` | types.md        | `out` parameter not assigned before return        | —                                                        |
| `TYP046` | types.md        | moved value used after move                       | —                                                        |
| `TYP047` | types.md        | optional type not narrowed                        | `types/optional-not-narrowed.q`                          |
| `TYP048` | types.md        | arb-width literal exceeds declared width          | —                                                        |
| `TYP049` | types.md        | arb-width narrow can fail                         | —                                                        |
| `TYP050` | types.md        | `bool` used as integer                            | —                                                        |
| `TYP051` | types.md        | integer used as `bool`                            | `types/int-as-bool.q`                                    |
| `TYP052` | types.md        | assignment to `let` binding                       | —                                                        |
| `TYP053` | types.md        | use of uninitialized binding                      | —                                                        |
| `TYP054` | types.md        | slice borrows outlive their bytes                 | —                                                        |
| `TYP060` | types.md        | parameter mode keyword in call argument           | `types/mode-keyword-in-call.q`                           |
| `TYP070` | types.md        | shape mismatch in tensor op                       | —                                                        |
| `TYP071` | types.md        | SIMD lane width mismatch                          | —                                                        |
| `TYP080` | types.md        | (note) prefer `if let Some(u)` form               | —                                                        |
| `TYP090` | types.md        | endianness not specified                          | —                                                        |

## Generics — `TYP100`–`TYP149`

| Code     | Owner           | Short message                                     | Test                                                     |
|----------|-----------------|---------------------------------------------------|----------------------------------------------------------|
| `TYP100` | generics.md     | generic argument count mismatch                   | —                                                        |
| `TYP101` | generics.md     | const-generic argument has wrong type             | —                                                        |
| `TYP102` | generics.md     | missing required generic argument                 | `generics/missing-generic-arg.q`                         |
| `TYP103` | generics.md     | cannot infer generic argument                     | —                                                        |
| `TYP104` | generics.md     | ambiguous generic argument                        | —                                                        |
| `TYP105` | generics.md     | where clause not satisfied                        | —                                                        |
| `TYP106` | generics.md     | unknown generic parameter                         | —                                                        |
| `TYP107` | generics.md     | const expression too complex                      | —                                                        |
| `TYP108` | generics.md     | non-default after default                         | `generics/non-default-after-default.q`                   |
| `TYP109` | generics.md     | cycle in generic defaults                         | —                                                        |
| `TYP110` | generics.md     | invalid type for const generic                    | —                                                        |
| `TYP111` | generics.md     | variance annotation not allowed                   | —                                                        |
| `TYP112` | generics.md     | higher-kinded parameter not allowed               | —                                                        |

## Faces — `TYP200`–`TYP249`

| Code     | Owner           | Short message                                     | Test                                                     |
|----------|-----------------|---------------------------------------------------|----------------------------------------------------------|
| `TYP200` | faces.md        | type does not fit face                            | —                                                        |
| `TYP201` | faces.md        | wrong fit form for single-param face              | `faces/wrong-fit-form-single.q`                          |
| `TYP202` | faces.md        | wrong fit form for multi-param face               | `faces/wrong-fit-form-multi.q`                           |
| `TYP203` | faces.md        | overlapping fits                                  | —                                                        |
| `TYP204` | faces.md        | coherence violation                               | —                                                        |
| `TYP205` | faces.md        | face arity mismatch                               | —                                                        |
| `TYP206` | faces.md        | missing associated type                           | —                                                        |
| `TYP207` | faces.md        | face is not dyn-safe                              | `faces/not-dyn-safe.q`                                   |
| `TYP208` | faces.md        | face inheritance cycle                            | —                                                        |
| `TYP209` | faces.md        | effect bound mismatch                             | —                                                        |
| `TYP210` | faces.md        | unsatisfied face bound                            | —                                                        |
| `TYP211` | faces.md        | wrong method signature in fit                     | —                                                        |
| `TYP212` | faces.md        | default method recursion                          | —                                                        |
| `TYP213` | faces.md        | auto-derive failed                                | —                                                        |
| `TYP214` | faces.md        | redundant `@no_derive`                            | —                                                        |
| `TYP215` | faces.md        | unknown face                                      | —                                                        |
| `TYP216` | faces.md        | unknown method on face                            | —                                                        |
| `TYP217` | faces.md        | missing method in fit                             | —                                                        |
| `TYP218` | faces.md        | property test law violated                        | —                                                        |
| `TYP219` | faces.md        | `@skip_laws` on a fit with no laws                | —                                                        |
| `TYP220` | faces.md        | overlapping methods in bound-disjoint face overload | —                                                      |

## Errors — `TYP300`–`TYP307`

| Code     | Owner           | Short message                                     | Test                                                     |
|----------|-----------------|---------------------------------------------------|----------------------------------------------------------|
| `TYP300` | errors.md       | `try` requires `Result` return type               | `errors/try-without-result-return.q`                     |
| `TYP301` | errors.md       | error conversion not available                    | —                                                        |
| `TYP302` | errors.md       | non-exhaustive match on `Result`                  | —                                                        |
| `TYP303` | errors.md       | `?.` on non-`Option` value                        | —                                                        |
| `TYP304` | errors.md       | (retired — `Result` destructure form removed)     | —                                                        |
| `TYP305` | errors.md       | `?` postfix on `Result`                           | `errors/question-on-result.q`                            |
| `TYP306` | errors.md       | `panic` payload does not fit `Panic`              | `errors/panic-payload-not-panic-fitting.q`               |
| `TYP307` | errors.md       | `catch` type is not `Panic`-fitting               | —                                                        |

## Memory / regions — `REG*`

| Code     | Owner           | Short message                                     | Test                                                     |
|----------|-----------------|---------------------------------------------------|----------------------------------------------------------|
| `REG010` | memory.md       | value outlives its region                         | —                                                        |
| `REG011` | memory.md       | borrowed value escapes its region                 | —                                                        |
| `REG012` | memory.md       | cross-region pointer without transfer             | —                                                        |
| `REG013` | memory.md       | implicit-scope arena alloc in `@no_alloc`         | —                                                        |
| `REG020` | memory.md       | linear pointer in `@managed` struct               | `memory/linear-in-managed.q`                             |
| `REG021` | memory.md       | managed reference in non-managed struct           | —                                                        |
| `REG030` | memory.md       | non-shareable field in `@shared` struct           | —                                                        |
| `REG031` | memory.md       | `@shared` struct passed by linear value           | —                                                        |
| `REG032` | memory.md       | shared region escapes its scope                   | —                                                        |
| `REG040` | memory.md       | region exited with live allocations               | `memory/region-exit-live-allocs.q`                       |
| `REG041` | memory.md       | nested region outlives parent                     | —                                                        |
| `REG042` | memory.md       | invalid region kind for operation                 | —                                                        |
| `REG050` | memory.md       | unknown transfer verb                             | `memory/unknown-transfer-verb.q`                         |

## Effects — `EFF*`

| Code     | Owner           | Short message                                     | Test                                                     |
|----------|-----------------|---------------------------------------------------|----------------------------------------------------------|
| `EFF100` | errors.md       | `panic` in `@no_panic` function                   | —                                                        |
| `EFF101` | errors.md       | `trap` in `@no_trap` function                     | —                                                        |
| `EFF102` | errors.md       | `@realtime` allocates on error path               | —                                                        |
| `EFF103` | errors.md       | `dyn Error` in `@no_alloc` path                   | —                                                        |
| `EFF104` | effects.md      | effect inference did not converge                 | —                                                        |
| `EFF110` | effects.md      | callee effect outside caller's set                | —                                                        |
| `EFF111` | effects.md      | undeclared capability picked up by inference      | —                                                        |
| `EFF112` | effects.md      | assert violated by callee                         | —                                                        |
| `EFF113` | effects.md      | type does not fit `@send`                         | —                                                        |
| `EFF114` | effects.md      | `@send` derivation failed                         | —                                                        |
| `EFF120` | effects.md      | contradictory effects declared                    | `effects/contradictory-effects.q`                        |
| `EFF121` | effects.md      | unknown effect marker                             | —                                                        |
| `EFF130` | effects.md      | declared effect set exceeded                      | —                                                        |
| `EFF131` | effects.md      | dependency uses denied effect                     | —                                                        |
| `EFF132` | effects.md      | declared effect unused (warning)                  | —                                                        |
| `EFF140` | effects.md      | user effect shadows core marker                   | `effects/user-effect-shadows-core.q`                     |
| `EFF141` | effects.md      | invalid effect name                               | `effects/invalid-effect-name.q`                          |
| `EFF150` | effects.md      | effect variable not bound                         | —                                                        |
| `EFF151` | effects.md      | effect variable conflicts with annotation         | —                                                        |
| `EFF160` | effects.md      | `@cancel` without ctx parameter                   | `effects/cancel-without-ctx.q`                           |

## Streams — `STR*`

| Code     | Owner           | Short message                                     | Test                                                     |
|----------|-----------------|---------------------------------------------------|----------------------------------------------------------|
| `STR010` | streams.md      | `@stage` on fn with no dataflow input             | —                                                        |
| `STR011` | streams.md      | `@stage` on fn with non-dataflow return           | —                                                        |
| `STR012` | streams.md      | `@stage` body uses forbidden feature              | —                                                        |
| `STR020` | streams.md      | dataflow type mismatch in pipeline                | `streams/dataflow-type-mismatch.q`                       |
| `STR021` | streams.md      | rate mismatch                                     | —                                                        |
| `STR022` | streams.md      | rate parameter must be `const`                    | —                                                        |
| `STR030` | streams.md      | direct stage recursion                            | —                                                        |
| `STR031` | streams.md      | sink stage upstream of another stage              | —                                                        |
| `STR032` | streams.md      | source stage downstream of another stage          | —                                                        |
| `STR040` | streams.md      | non-stage in pipeline                             | —                                                        |
| `STR050` | streams.md      | unbroken feedback cycle                           | —                                                        |
| `STR051` | streams.md      | `pre()` on `Event<T>`                             | `streams/pre-on-event.q`                                 |
| `STR052` | streams.md      | `pre()` outside a stage body                      | —                                                        |
| `STR060` | streams.md      | `@realtime × |>` effect violation                  | `streams/realtime-pipe-violation.q`                      |
| `STR061` | streams.md      | non-`@send` payload crossing thread boundary      | —                                                        |
| `STR062` | streams.md      | `SharedSignal` with non-`@send` `T`               | —                                                        |
| `STR063` | streams.md      | multiple writers on `SharedSignal`                | —                                                        |
| `STR064` | streams.md      | `.output()` on a sink-terminated graph            | —                                                        |

## Concurrency — `CONC*`

| Code     | Owner           | Short message                                     | Test                                                     |
|----------|-----------------|---------------------------------------------------|----------------------------------------------------------|
| `CONC010`| concurrency.md  | handle escapes its scope                          | —                                                        |
| `CONC011`| concurrency.md  | use of consumed handle                            | —                                                        |
| `CONC012`| concurrency.md  | `@cancel` call from `@uncancellable` context      | —                                                        |
| `CONC013`| concurrency.md  | `@uncancellable` inside `@realtime` (redundant)   | —                                                        |
| `CONC020`| concurrency.md  | `tell` on a reply-bearing handler                 | `concurrency/tell-on-reply-handler.q`                    |
| `CONC021`| concurrency.md  | `ask` on a non-reply handler                      | —                                                        |
| `CONC022`| concurrency.md  | outside access to actor `state`                   | —                                                        |
| `CONC030`| concurrency.md  | `spawn` inside a `catch` block                    | —                                                        |
| `CONC031`| concurrency.md  | `spawn` outside any `scope`                       | —                                                        |
| `CONC032`| concurrency.md  | `actor` handler not declared in face              | —                                                        |
| `CONC033`| concurrency.md  | unreachable `catch` arm                           | —                                                        |
| `CONC040`| concurrency.md  | `select` without timeout or cancel branch (lint)  | —                                                        |
| `CONC041`| concurrency.md  | `select` with no `ctx: Cancel` in scope (lint)    | —                                                        |
| `CONC050`| concurrency.md  | channel policy required                           | `concurrency/channel-policy-required.q`                  |
| `CONC051`| concurrency.md  | `Unbounded` channel (lint)                        | —                                                        |
| `CONC052`| concurrency.md  | non-`@send` payload in cross-thread channel       | —                                                        |
| `CONC053`| concurrency.md  | `for x in rx` over cancel-aware receiver without ctx | `concurrency/for-cancel-aware-without-ctx.q`           |

## Environment and capabilities — `ENV*`

| Code     | Owner           | Short message                                     | Test                                                     |
|----------|-----------------|---------------------------------------------------|----------------------------------------------------------|
| `ENV010` | env.md          | (retired — replaced by ambient capability model)  | —                                                        |
| `ENV011` | env.md          | (retired — companion to ENV010)                   | —                                                        |
| `ENV020` | env.md          | `.mock()` outside `@test` context                 | —                                                        |
| `ENV030` | env.md          | capability denied (runtime)                       | —                                                        |
| `ENV040` | env.md          | manifest / derived capability mismatch            | —                                                        |
| `ENV041` | env.md          | manifest declares unused capability               | —                                                        |
| `ENV050` | env.md          | `main` Form 2 ends without return                 | `env/main-form2-no-return.q`                             |
| `ENV051` | env.md          | `main` not declared                               | —                                                        |
| `ENV052` | env.md          | `main` signature mismatch                         | `env/main-signature-mismatch.q`                          |
| `ENV053` | env.md          | `with_capabilities` outside any scope             | —                                                        |
| `ENV054` | env.md          | `with_capabilities` body uses non-blocking guard  | —                                                        |
| `ENV055` | env.md          | `with_capabilities(use:)` field not on `Env`      | `env/use-field-not-on-env.q`                             |
| `ENV056` | env.md          | `env` reference from `@pure` function             | `env/ambient-env-in-pure.q`                              |

## Golden positive tests

End-to-end programs that exercise multiple specs and must parse +
type-check with no diagnostics. Each is its own scenario and is not
keyed to a specific code.

| Test                                       | Exercises                                                                                  |
|--------------------------------------------|--------------------------------------------------------------------------------------------|
| `golden/hello-world.q`                     | Minimal `fn main`, string literal, ambient `env.out`.                                      |
| `golden/library-face-fit.q`                | `pub face` + `pub fit` + `pub fn<T: Face>` + array literal + `for` loop + interpolation.   |
| `golden/scope-spawn-catch.q`               | `scope { spawn … } catch (e: Panic) { … }`, nested scopes.                                 |
| `golden/graph-pipe-stages.q`               | `@stage`, `@fuse`, `graph`, `|>`, `Signal<T, R>` rate parameter, `Handle.cancel()`.        |
| `golden/result-and-try.q`                  | `enum`, `pub fit … : From<…>`, `Display`, `Error`, `try`, `Result`, `main` Form 2.         |

## Next batches

Once a parser exists and the corpus runs, the next coverage batches
are (in rough priority order):

1. The remaining `NAM*` codes that need a multi-file test surface
   (NAM005 collision, NAM006/NAM007 cross-qube re-export rules,
   NAM008 cycle). These need the `<stem>.dir/` multi-file convention
   added to `README.md`.
2. The `TYP041` / `TYP044` / `TYP045` / `TYP046` mode-and-mutability
   battery — pure single-file tests, high coverage value.
3. `EFF110` / `EFF111` / `EFF112` propagation cases — these are the
   effect system's load-bearing checks and warrant ten-plus tests
   each covering capability, assert, and `+`-composed sets.
4. Stream `STR021` rate-mismatch and `STR031` / `STR032` sink/source
   placement — needed before `@realtime` audio tests are trustworthy.
5. Memory `REG010` / `REG011` / `REG012` lifetime cases — depend on
   the lifetime checker being far enough along to fire.
