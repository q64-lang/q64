# todo

Active work tracker. Things to do, things to decide, kept short and
ticked off as they land. Long-form design questions are tracked separately; this file is
for items the next session should be able to pick up and act on.

## Roadmap — sequenced phases (the map over the sections below)

A dependency-ordered view of the backlog. The detailed, line-level items
live in the topic sections further down; this is the *order* to do them in
and what gates what. Each phase links the section(s) that hold the work.

**Phase 0 — front-end + core codegen — DONE.** Lexer, structured parser
(items/exprs/stmts), the sema check pass, the **diagnostic ladder at
51/51 conformance**, the HIR/MIR two-tier IR, cross-module linking,
wasm32/wasm64 dual address space, component emission v0, the `qube` CLI +
Continuum registry (live), and the QView reactive-state architecture POC
(iPad-verified). This is the "you can lint + run real q64" milestone.

**Phase 1 — Codegen & language breadth — IN PROGRESS, *no gate* (do in
parallel).** Grow how much of the language actually executes. None of this
needs the platform audit, so it's the highest-leverage near-term work.
  - Generics beyond v0 monomorphization (§"B5 — generics beyond the first rung").
  - Numeric tower (§"Numeric tower"): f64/f32/narrow-int **and** the full
    native float-math builtin set (`sqrt`/`abs`/`floor`/`ceil`/`trunc`/
    `nearest`/`min`/`max`/`copysign`) **done**; remaining = the
    transcendentals (`sin`/`cos`/…) via `q64.math` (gated on loadable stdlib
    qubes), and receiver-expression / record-field float receivers.
  - Strings/lists beyond the floor + `str`/list **component exports** (§"Strings…", §"Component emission").
  - **`Vec.map` + `Vec.filter` + `Vec.reduce` done.** map/filter build a fresh
    vec (`tryVecMap`, desugar `var d = Vec.new(); for x in xs { … }` — loop var
    IS the lambda param, so body + captures resolve by ordinary scoping; map
    pushes the body, filter pushes the element under an `if pred`). reduce folds
    to a **scalar** (`tryVecReduce`, desugar `var total = init; for x in xs {
    total = body }` — the binding IS the accumulator, the 2nd lambda param is
    the loop var, the 1st (`acc`) is substituted to the accumulator via
    `Scope.subst`). `v.map(|x| x*10)` → [10,20,30]; `v.filter(|x| x%2==0)` keeps
    evens; `v.reduce(0, |acc,x| acc+x)` = 15, `reduce(1, |a,x| a*x)` = 120; all
    capture locals. **Method chaining done:** `xs.filter(p).map(f)` (and deeper)
    works — the outer parses as a `METHOD_EXPR` over the inner call;
    `vecReceiverName` recursively resolves the receiver, materializing each
    inner `map`/`filter` stage into a hidden `#chainN` temp vec
    (`buildMapFilterInto` is the shared loop), and the final stage builds into
    the binding. `v.filter(|x| x%2==0).map(|y| y*10)` → sum 120;
    `v.map(…).filter(…).map(…)` (3 stages) → 44. Runs wasm64 + wasm32.
    **Boundary:** main-only; i64; expr-body lambdas; `.reduce` mid-chain
    (it ends a chain since it yields a scalar) is fine, but chaining *after* a
    reduce isn't a vec source.
  - Closures / lambdas (`spec/closures.md`). **Slice 1 (parsing) done:**
    `LambdaExpr := "|" IDENT,* "|" Expr` parses (`|x| x*2`, `|| 42`,
    `|a,b| { … }`) — a leading `|`/`||` in primary position is
    unambiguously a lambda (bitwise/logical-or are infix); `ast.LambdaExpr`
    exposes `params()`/`body()`; lossless round-trip + the `graph-pipe-stages`
    golden's `|x| …` now parses structured. **Slice 2 (sema typing) done:**
    `checkLambdas` emits **TYP350** when a lambda has no expected `fn` type
    (an unannotated/non-`fn`-annotated `let`, or a bare `|x| …` statement)
    and **TYP351** on an arity mismatch against a `fn(...)`-typed annotation
    (`fnTypeArity` counts the annotation's params). Lambdas in call-argument
    position are left alone (the callee may expect a `fn` — resolving that is
    a follow-on); TYP352 (assign to an immutable capture) needs capture
    analysis, deferred. 1 check case (5 asserts); no conformance test (closures
    aren't in the corpus) but the golden's `.map(|x| …)` stays clean.
    **Slice 3a (fn-type parsing) done:** `FnType := "fn" "(" TypeExpr,* ")"
    ("->" TypeExpr)?` parses structured (FN_TYPE / FN_TYPE_PARAMS /
    FN_TYPE_PARAM) instead of a raw blob; `TypeExpr.cast` maps `FN_TYPE` →
    `.raw` so `let f: fn(i64)->i64 = …` annotations are recognized (TYP350/351
    read them). Round-trips losslessly; parser test. **Slice 3b (the big one,
    the lowering):** monomorphizing, non-escaping specialization — at a call
    `apply(|n| n*2, x)` where `apply(f: fn(i64)->i64, …)` has a fn-typed param,
    stamp a specialized `apply` whose `f(args)` sites are **inlined** with the
    lambda body (params bound to the args; captures aliased; no env box). This
    touches `registerFunc`/`collectCalleeParams`/the body builders (load-
    bearing — every function) and mirrors the B5 `stampGeneric` machinery; it's
    a multi-increment change to do carefully with the suite green at each step.
    **Slice 3b done — closures run.** `fn apply(f: fn(i64)->i64, x: i64) -> i64
    { f(x) }` + `apply(|n| n*2, 21)` → 42, end-to-end on wasmtime (wasm64 +
    wasm32). The lowering, as planned: (i) `collectCalleeParams` skips a
    `fn`-typed param (no runtime slot — `paramIsFnTyped`, via 3a's structured
    FN_TYPE); (ii) `buildHofCall` → `stampHof` specializes the callee per
    lambda (deduped by `callee#L<offset>`, mirrors `stampGeneric`), the lambda
    riding on `Scope.hof_name`/`hof_lambda`; (iii) `buildIntExpr`'s `.call` arm
    inlines a `hof_name(args)` call (`inlineLambda`) by building the lambda body
    with its params substituted (`Scope.subst`, read in the `.path` arm) by the
    built args. Verified: two lambdas → two stamped instances; richer bodies
    (`let a = f(x)\n a + f(x)` → 60); a **const-capture** (`|n| n*gain` where
    `gain` folds) → 20; non-lambda arg to a fn param rejected. link-roundtrip
    closures section + build_hir test; conformance 51/51, all round-trips + CLI
    green. **Boundaries (follow-ons):** true *runtime* alias-capture (a `var`
    or non-const captured binding — only const-foldable captures resolve
    today); multiple fn-typed params; block-body lambdas (`|x| { … }`); a
    complex arg to `f(...)` used multiply (shared expr → would double-eval);
    str/record/closure-returning HOFs. **TYP352** (assign to an immutable
    capture) also still pending. Real `.map`/iterator HOFs build on this.
    **Runtime alias-capture done:** a lambda's free scalar locals
    (`var g = …; apply(|n| n + g, 10)` → 14) are now **capture-by-extra-
    parameter** — `collectCaptures` finds the free single-segment scalar idents
    that resolve in the call-site scope, `buildHofCall` appends their values to
    the call, and `stampHof` declares them as extra params after the ordinary
    ones (read by name in the inlined body). Sound for a downward-only,
    non-mutating closure (capture-by-value of the current binding). Verified
    end-to-end wasm64 + wasm32 (roundtrip: `+107` from a `var base` capture) +
    a build_hir test. **Still deferred:** capture *mutation* / write-back
    (TYP352-adjacent), non-scalar (record/str) captures, block-body lambdas,
    multiple fn params.
  - Units & dimensional arithmetic (`spec/units.md`; lexed, not evaluated).
  - Integer ranges + `for i in lo..hi` **done:** `..`/`..=` parse as a
    `RANGE_EXPR` (a low-precedence binary op in `parseBinExpr`); `ast.RangeExpr`
    exposes `lo()`/`hi()`/`inclusive()`; `buildForRange` desugars a `for` over a
    range to a counted `let i = lo; while i < hi { body; i = i+1 }` (`<=` for
    `..=`), bounds evaluated once. Runs wasm64 + wasm32 (roundtrip ranges
    section: exclusive / inclusive / variable bounds → 3/15/14). Now works in
    **callee bodies too** (`buildIntForRange`: same counted-loop desugar, body
    via `buildIntStmt`, returned as one block) — `fn sum_to(n) { var s=0\n for i
    in 1..=n { s=s+i }\n s }` → 5050.
  - **Vec parameters + callee `for`-over-Vec done:** a function can take a
    `Vec<i64>` parameter and iterate it. `collectCalleeParams` recognizes a
    `Vec<…>` param (one `.ptr`, registered in `scope.vecs`); a per-fn
    `fn_vec_params` flag list lets `buildCallArgs` pass a caller's Vec by its
    base pointer (a new `.vec` ParamKind); `buildIntForVec` lowers `for x in
    xs` in the callee (index loop with `vec_get`/`vec_len`). `fn total(xs:
    Vec<i64>) { for x in xs {…} }` + `total(Vec.from([10,20,5]))` → 35/20,
    wasm64 + wasm32. **Boundary:** local `Vec.new()`/`for` *inside* a callee
    (vec creation in callee bodies) and array `for` in callees are follow-ons;
    `Vec.new()` as an initializer still isn't a recognized form (`Vec.from`
    only); ranges as general values (`let r = 0..n`) too.
  - Pattern-grammar completion (§"Other open items" — close the `(* open *)` markers).
    - [x] **Or-patterns** (`Red | Yellow -> …`, `1 | 2 | 3 -> …`): `parseOrPattern`
          wraps `Pattern ("|" Pattern)*` in an `OR_PATTERN` (`ast.Pattern.
          alternatives()`); the match builders (`buildMainMatch`,
          `buildMatchInto`, `buildVoidMatch`, `buildIntMatch`) expand an or-arm
          into one `(tag, body)` per alternative sharing the body, marking each
          for exhaustiveness. v0: unit-variant + integer-literal alternatives
          (no payload binders across alts). Runs wasm64 + wasm32 (roundtrip
          `caution / 10 / 20`).
    - [x] **Guards** (`P if cond -> …`): `parseMatchGuard` parses `if <expr>`
          into a `MATCH_GUARD` cst node between the (or-)pattern and `->`
          (`ast.MatchArm.guard()`); all four match builders AND the guard onto
          the arm's tag test in `foldMatchChain` (a failing guard falls through
          to the rest of the chain). A scalar `x if cond -> …` binder arm
          aliases the scrutinee value (`aliasLocal`) so the guard and body can
          read it; it matches any value, so its `LoweredArm.any` condition is
          the bare guard. A guarded arm never satisfies exhaustiveness on its
          own — an unguarded fallback (a plain arm or `_`) is still required.
          v0: guards on unit/literal/scalar-binder arms (no payload-binding
          arms — the prelude loads run inside the body, after the guard). Runs
          wasm64 + wasm32 (roundtrip `400/51/0 / one-plain / go-fast`). Also
          fixed a pre-existing or-pattern losslessness bug (trivia before the
          first `|` was dropped).
    - [x] **Range patterns** (`1..5 ->`, `10..=20 ->`): a literal low bound
          followed by `..`/`..=` and a high bound parses into a `RANGE_PATTERN`
          (`ast.Pattern.rangeParts()` → `{lo, hi, inclusive}`). On a scalar
          (non-enum) match, `buildRangePatternCond` lowers it to the bounded
          test `(scrut >= lo) and (scrut <op> hi)` (`<` for `..`, `<=` for
          `..=`) read from the scrutinee local, ANDed with a user guard if
          present; it rides the `any`-arm machinery (no tag), so it needs an
          unguarded `_` fallback. v0: integer bounds only. Runs wasm64 + wasm32
          (roundtrip `0/1/2/2/9 / mid-ok`).
    - [x] **Literal sub-patterns in payload arms** (`Move(0, y) -> …`): a
          literal in a tuple-struct/enum-variant slot adds a slot-equality
          condition. `resolveArmPattern` reads the slot directly (no binding)
          and ANDs `(slot == lit)` onto the arm via `ArmPattern.cond`; the
          builders fold it together with any user guard (`andOpt`), and a
          conditional payload arm never satisfies exhaustiveness on its own
          (it falls through to the unconditional binder arm). `matchValueTy`
          now aliases payload binders (`aliasPatternBinders`) so a first arm
          whose value uses them type-probes. v0: integer slots. Runs wasm64 +
          wasm32 (roundtrip `7 / 5 / 999`). **Next:** nested enum/record
          sub-patterns (`Wrapper(Some(x))`, `Circle { r }` field destructuring).
    - [x] **Immediate (all-unit) enum params in callees** (fixed a pre-existing
          gap): `collectCalleeParams` rejected an all-unit enum param because
          `structOfType` returns null for it (only *boxed* enums are records).
          Now `enumOfType` recognizes it and the param rides as an i64 tag,
          registered in `scope.enum_binds` so `match c { … }` resolves bare
          variants — in both the value-`let` and statement-return callee forms.
          Runs wasm64 + wasm32 (roundtrip `2/3/10/30`). (Boxed-payload enum
          params already worked.)
    - [x] **Record `let`-destructuring** (`let P { x, y } = p`): single-level
          record destructuring (spec/grammar.md §Patterns `RecordStructPattern`).
          `buildRecordDestructure` stashes the record's base pointer in a hidden
          local, then binds each named field to a fresh local via `field_get`
          at the field's offset (`ast.Pattern.recordFields()` →
          `FieldPattern{name, subPattern}`). Supports rename (`x: a`) and
          partial (`P { x }`) forms, in `main` and callee bodies. v0: i64
          fields, plain (non-nested) binders. Runs wasm64 + wasm32 (roundtrip
          `7 / 12 / 25 / 3`).
    - [x] **Tuple-literal destructuring** (`let (a, b) = (e1, e2)`): q64 has no
          first-class tuple value yet, so this is the parallel-binding form —
          `buildTupleDestructure` requires the RHS to be a tuple *literal* and
          binds each element to the LHS's ident sub-patterns (arity-checked).
          Works in `main` and callee bodies; v0: i64/bool/float elements, ident
          binders. A non-literal RHS (`let (a, b) = pair`) and arity mismatch
          reject honestly. Runs wasm64 + wasm32 (roundtrip `7 / 60 / 10 / 105 /
          35`).
    - [x] **First-class tuple values** (`let t = (3, 4)`, `t.0`, `let (a,b)=t`):
          a tuple is an anonymous record — `tupleStructInfo` synthesizes a
          `StructInfo` (fields "0", "1", … laid out by natural alignment), so
          the whole record ABI is reused: `buildRecExpr` gains a `.tuple` arm
          (record_alloc into the scope arena), `buildIntExpr` a `.tuple_field`
          arm (`t.N` → field_get), the `main` let path binds a tuple literal
          via `bindMainRecord`, and `buildTupleDestructure` reads a tuple
          binding's fields (`let (a, b) = t`) as well as the parallel-literal
          form. v0: i64 elements, main-position bindings. An out-of-range index
          rejects. Runs wasm64 + wasm32 (roundtrip `3/4/7/12/60/16`).
    - [x] **Tuple params + returns** (`fn divmod(..) -> (i64, i64)`, `p: (i64,
          i64)`): `structOfType` recognizes `TUPLE_TYPE` and synthesizes the
          (interned) tuple `StructInfo`, so a tuple type flows through the whole
          record param/return ABI — a `-> (i64, i64)` body whose tail is a tuple
          literal returns a `.ptr` record, a tuple param is a `.ptr` with `p.N`
          indexing, `let (q, r) = divmod(..)` reads the returned record, and a
          tuple binding *or* literal passes as a tuple arg (matched by the
          interned layout's pointer identity). True multi-value return. v0: i64
          elements. Runs wasm64 + wasm32 (roundtrip `3/2/2/17/123`).
    - [x] **f64/bool tuple slots + record-field destructure** (per-slot typing):
          added a `fieldType` callback to `sema/exprtype.Env` (+ `.field` /
          `.tuple_field` cases in `scalarOf`), so a tuple slot / field-of-expr
          types from the record layout (`t.1` → f64) instead of defaulting to
          the i64 print/compute path. The bridge resolves a path base through
          `scope.recs`. Lifted the i64-only restriction on tuple elements
          (construction/index/destructure/params/returns) and record `let`-
          destructure to **i64/f64/f32/bool**. A mixed tuple `(true, 3.5)`
          prints `true` then `3.5`. Runs wasm64 + wasm32 (roundtrip
          `4.0/true/3.5/4.5/6.0`). **Next (deferred):** narrow/str tuple+field
          slots, field-of-*call* typing (`divmod(..).1` as f64), nested struct
          destructuring, plain struct-value `match`.
  - Memory reclamation — Stack discipline on the implicit arena (§"Memory reclamation").
  - **Structured parsing of the currently-raw block constructs**
    (`graph`/`scope`/`region`/`actor` bodies, leading annotations) — lets the
    token-scan diagnostics (STR/CONC/REG/EFF) become precise AST-level checks,
    and is a prerequisite for clean concurrency/stream *lowering* later.
    - [x] **Leading item annotations** (`@stage`/`@managed`/`@http_handler`):
          `itemKeyword` skips a leading `@name(args)?` run, `parseItem`
          consumes them into `ANNOTATION` nodes and prepends them to the item,
          and `ast.Annotation`/`FnDecl.annotations()`/`StructDecl.annotations()`
          /`ast.hasAnnotation` expose them. REG020 now reads `@managed` from
          the struct node instead of scanning sibling tokens (lossless
          round-trip held; 51/51 + goldens green). Block bodies
          (`graph`/`scope`/`region`/`actor`) are the next slice.
    - [x] **Structured concurrency forms** (`scope`/`spawn`/`select`/`catch`):
          `parseScopeStmt` (`ScopeStmt := "scope" EffectAnnot? Block CatchArm*`),
          `parseSpawn` (`spawn Block` / `spawn scope …`, an expression in
          primary position), `parseSelectStmt` + `parseSelectArm`
          (`(Pattern "=")? Expr "->" (Block|Expr)`), and `parseCatchArm`. Wired
          into `parseStmt` (scope/select) and `parsePrimary` (spawn). New AST
          views: `ScopeStmt{effectSpec,block,catchArms}`, `CatchArm{binding,
          errorType,block}`, `SpawnExpr{block,scopeStmt}`, `SelectStmt{arms}`,
          `SelectArm{binding,operation,block}` (+ `Stmt.scope_stmt`/`select_stmt`,
          `Expr.spawn`). `resolve`/`check` walk the new blocks/arms (binding the
          catch error + select result names). Lossless round-trip (4 forms) +
          an AST-structure test; `q64 check` accepts a full scope/spawn/select/
          catch program. Codegen is gated on the Phase-2 audit; this is the
          host-independent front-end Phase 3/4 will lower. Remaining raw:
          `graph`/`actor`/`region` bodies, `channel(…)`.
  - `screen`/`draw` → `main` **lowering** + the browser-host glue wiring
    (§"QView…" — parse/AST done; lowering + `runtime/web` reading the i32
    `env.out` args remain).

**Phase 2 — Platform feature audit — THE GATE — DECISION RECORDED
(2026-06-14).** §"Wasm 3.0 feature audit". Matrix recorded in
`spec/memory.md` §"Concurrency platform audit": **stack-switching ships on
no host q64 targets** (wasmtime 45 has no C-API toggle; no browser stable);
tail-call/EH/GC are broadly available; threads need COOP/COEP. **v0
concurrency floor = single-threaded cooperative scheduler** (suspend only at
statically-known points, selective CPS lowering — not asyncify); threads +
stack-switching are capable-host upgrades behind the same scheduler. This
unblocks Phase 3. Remaining: the live `WebAssembly.validate` browser-probe
harness (confirm the WebKit/iPad column empirically) + maintainer sign-off on the
floor. Everything in Phase 3+ now has its target.

**Phase 3 — Concurrency runtime — gated on Phase 2 — STARTED.** Implement
the chosen floor: the scheduler, `spawn` + structured `scope` execution,
`channel` send/recv with the policies already diagnosed (Backpressure/
LatestValue/RingBuffer/Unbounded), and `actor` `tell`/`ask` dispatch. Then
the runtime effect checks the front end can't do statically (EFF110 assert/
operation violations, `@cancel` propagation). Specs: `concurrency.md`,
`concurrency-model.md`.
  - [x] **`scope` + statement `spawn` execution (cooperative v0).**
        `buildScopeStmt` lowers `scope { … }` on the cooperative floor with
        **eager-at-spawn** scheduling: each task runs to completion at its spawn
        point (a valid no-preemption schedule). Same-frame, so a task sees the
        scope's locals directly — no closure box, no task funcref. (Originally
        hoist-to-join; switched to eager because it handles parent-local
        dependencies AND lets a spawned producer fill a channel before the
        parent consumes — see Channels below — and it unifies with the eager
        `let h = spawn` handle model. Both orderings are valid cooperative
        schedules.) `scope { spawn { env.out(base+1) } env.out("p")
        spawn { env.out(base+2) } }` → `p / 101 / 102`. Runs wasm64 + wasm32
        (link-roundtrip `start/parent/101/102/100/done`). **Boundaries / next
        slices:** suspension + `await` (the CPS transform for genuinely
        suspending tasks), `let h = spawn` + `Handle`/`await`, `select`
        execution, `channel` send/recv, `catch` arms (need the EH runtime),
        `spawn scope` sugar, and scope/spawn in callee/void bodies (v0 is
        main-position). A spawn referencing a not-yet-declared scope local is
        caught by `resolve` (lexical order) before the hoist.
  - [x] **`scope`/`spawn` in callee (void) bodies.** `buildVoidScopeStmt`
        mirrors the main-position lowering through `buildVoidStmt`, so a `fn
        worker() { scope { spawn … } }` runs its tasks eager-at-spawn.
        `worker(1); worker(2)` → `10/1/100/20/2/200`. Runs wasm64 + wasm32.
        (Value-callee `scope` remains a follow-on.)
  - [x] **`let h = spawn { e }` + `h.await()` (handle results).** Key
        realization: a task that doesn't *itself* suspend needs **no** state
        machine — `await` is just "run to completion (already done, eagerly) and
        read the result." `buildSpawnLet` binds the handle to the task's eager
        result value; `h.await()` (which parses as a call to the dotted path
        `h.await`, since `await` isn't a keyword) reads it back, in both
        `buildIntExpr`'s `.call` arm and the `callRet`/`scalarOf` typing bridge
        (result type = receiver type, so f64 handles stay f64). `let h1 = spawn
        { compute(6) }; … h1.await() + h2.await()` → 85; an f64 handle → 4.5.
        Runs wasm64 + wasm32. Multi-statement task bodies lower as a value
        block (leading statements for effect, tail = handle value): `let h =
        spawn { let x=10\n let y=20\n x+y }` → 30.
  - [x] **`spawn scope { … }` sugar.** `spawnExprOf` carries the whole spawn
        expression, so an eager-at-spawn task is either a `spawn { block }`
        (inline its statements) or a `spawn scope { … }` (run the nested scope,
        whose own spawns run eager-at-spawn too) — in both main and callee
        positions. Nested structured concurrency:
        `spawn scope { spawn { … } … }` → `inner-a/inner-parent/outer-parent`.
        Runs wasm64 + wasm32.
  - [x] **Channels v0 — FIFO buffer (CPS increment 1).** `let ch =
        channel(...)` lowers to a Vec buffer + an i64 read cursor (`scope.chans`
        + `scope.vecs`); `ch.send(x)` is a `vec_push`; `let v = ch.recv()` is
        `v = buf[cursor]; cursor += 1`. i64 elements. **Key finding that frames
        the rest of the CPS work:** task-internal suspension is only
        *observably* needed for channels — handle-await DAGs already run
        topologically under the eager model. **The natural idiom now works via
        eager-at-spawn** (see `scope` above), not a state machine: the spawned
        producer runs to completion at its spawn point, filling the buffer
        before the parent's `recv`s — `scope { let ch = channel(); spawn {
        ch.send(10/20/30) } let a = ch.recv() … }` → 60 (wasm64 + wasm32), no
        suspension. **Still genuine CPS work (next):** a *consumer spawned
        before its producer* (true mutual suspension — `recv`-on-empty must
        yield to a later task), `send`-on-full backpressure (v0 channels are
        unbounded), and a *suspending* `select`. The eager floor covers
        producer-before-consumer DAGs (the common case).
  - [x] **`select` v0 — first-ready-wins.** `buildSelectStmt` lowers
        `select { v = ch.recv() -> body, … }` to an if / else-if chain: each
        arm's readiness is `cursor < vec_len(buf)`, the first ready arm performs
        its `recv` (binding the value or discarding it with `_`), bumps the
        cursor, and runs its body (block or `-> expr`). No else — a
        non-suspending select falls through when nothing is ready (a *parking*
        select waits for the scheduler). `select { v=a.recv()->…, w=b.recv()->… }`
        with `b` ready → the b arm; both ready → the first arm. Runs wasm64 +
        wasm32 (`100 / 7`). **Still needs the scheduler:** parking when no arm
        is ready, and `send` arms / send-on-full.

  - [x] **Pipe operator `|>`** (lowering). `lhs |> f(args)` ≡ `f(lhs, args)` —
        the piped value becomes the first argument (reusing `buildCallArgs`'s
        receiver slot); `lhs |> f` (bare path) is `f(lhs)`; chains are
        left-associative so `x |> a |> b` is `b(a(x))`. Typed via a new
        `Env.fnRet` callback (return type by function name) so an f64 path stage
        (`9.0 |> half`) formats correctly. `5 |> dbl |> inc` → 11, `10 |>
        add(5)` → 15, `3 |> dbl |> add(100) |> inc` → 107, `9.0 |> half` → 4.5.
        Runs wasm64 + wasm32. (Method-call pipe targets `x |> r.m()` are a
        follow-on; this is the function-pipe used across the corpus and the core
        of the stream `|>` syntax.)
  - [x] **Structured `actor` declarations** (parsing). `parseActorDecl`
        (`actor IDENT GenericParams? "{" (StateDecl|HandleDecl)* "}"`) +
        `parseHandleDecl` (`handle IDENT (Params)? ("->" TypeExpr)? Block`),
        wired into `itemKeyword`/`isItemKeyword`/`parseItem`. New AST views
        `ActorDecl{name,states,handlers}` + `HandleDecl{name,params,returnType,
        body}` (+ `Item.actor_decl`, `SymbolKind.actor` so the name binds and
        resolves). Structurally a `screen` with `handle` methods. Lossless
        round-trip + an AST-structure test; `q64 check` accepts an actor.
        **Codegen next:** lower an actor to a state record + handler functions,
        with `tell`/`ask` as (eager, cooperative-floor) calls on the instance —
        reusing the record + fit-method machinery.
  - [x] **Actors v0 — state record + handlers (tell/ask).** `registerStructs`
        registers an actor as a struct of its `state` fields (+ keeps the decl
        in `b.actor_decls`); `registerActorHandler` builds each `handle` as a
        callee taking the state record as an implicit `self` (`.ptr`), keyed
        `Name.handler` like a fit method so the dotted-call dispatch finds it.
        Inside a handler, a **bare state-field name** resolves to `self.<field>`
        for read, write, and typing via `scope.self_actor` + `actorStateField`.
        A void handler is a `tell` (`tryActorTell` — statement dispatch); a
        `-> T` handler is an `ask` (the value method path). `Counter { state n;
        handle bump(); handle add(k); handle get() -> i64 }` with `c.bump();
        c.bump(); c.add(10); c.get()` → 12 (state persists across calls).
        Runs wasm64 + wasm32. v0: explicit construction `Counter { n: 0 }`
        (default-fill `Counter {}`, void handlers in callee bodies, and `ask`
        suspension are follow-ons).

**Phase 4 — Streams / dataflow runtime — builds on Phase 3 — STARTED.**
  - [x] **Structured `graph` declarations** (parsing). `parseGraphDecl`
        (`graph IDENT GenericParams? "(" Params? ")" ("->" TypeExpr)? Block`),
        wired into `itemKeyword`/`isItemKeyword`/`parseItem`. New AST view
        `GraphDecl{name,params,returnType,body}` (+ `Item.graph_decl`,
        `SymbolKind.graph`). The body is `let` stage bindings whose RHS is a
        stage call or a `|>` pipeline (the pipe lowering already exists). Lossless
        round-trip + an AST-structure test; `q64 check` accepts a graph.
        **Codegen next:** walk the desugared stage call-tree to build the
        topology; v0 can run a graph eagerly (stages are just function calls via
        `|>`) on the cooperative floor, like the rest of Phase 3.

**Phase 4 (cont.) — Streams / dataflow runtime — builds on Phase 3.** The graph
scheduler (stages as tasks), the `|>` pipe runtime, and Signal/Event/Stream
sampling semantics. The STR0xx diagnostics already guard the front end;
this makes graphs *run*. Spec: `streams.md`.

**Phase 5 — Reactivity productionization — builds on the QView POC +
Phase 3/4.** `@state(scope)` as first-class syntax + AST partitioning, the
typed twin `face`/RPC API beyond `inc`, MSDF text, and the full retained
`Renderer` face. Specs: `reactivity.md`, `agent-ui.md`.

**Cross-cutting / later (independent of the critical path).** RPC + `@wire`
(`rpc.md`); the full memory model — `Managed`/WasmGC heap, named regions,
`transfer` runtime (`memory.md`); C bindings / vendoring Binaryen
(§"C bindings"); the host ABI for non-trivial faces (§"Host ABI…"); `spec/
ffi.md` (unwritten); and the native **LLVM** backend (explicitly "Later").

**Critical path:** Phase 2 → 3 → 4, with 5 depending on 3/4. Phase 1 and
the cross-cutting bucket run in parallel and need no gate. The single
hard ordering constraint in the whole plan is **audit-before-scheduler**.

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
- [x] **Logical not (`!`).** `!` was already lexed (`BANG`) and parsed as a
      prefix op; wired the IR/codegen tail: `ops.UnKind.not`, `build_hir.unKind`
      maps `.BANG`, `lower` types `not` as a boolean (i32 0/1), `emit` lowers it
      to `eqz` (width follows the operand — i32 for a comparison, i64
      otherwise), and `consteval` const-folds it. It's truthiness
      (`x == 0 ? 1 : 0`), so it accepts any integer operand. Verified
      end-to-end via the wasmtime host: `if !is_even(n)`, `!0`/`!5`, `!!5`.
- [x] **Short-circuit `&&` / `||`.** Completes the boolean operator set. Both
      were already lexed (`AMP_AMP`/`PIPE_PIPE`) and parsed with precedence
      (`||`=2, `&&`=3) but didn't lower. They're control flow, not value ops:
      a new `hir.Expr.logical` node (`ops.LogicalKind`) lowers to a value
      `if_` — `a && b` → `if a { b } else { 0 }`, `a || b` → `if a { 1 } else
      { b }` — yielding an i32 0/1 (matching comparisons + `!`). Added a
      `mir.const_i32` for the boolean branch leaves. Both operands are
      truthiness-tested, so the rhs need not be a 0/1. Verified end-to-end:
      full truth tables, precedence (`a || b && c`), interaction with `!`, and
      **short-circuit** (a div-by-zero rhs is skipped, not trapped) when the
      lhs already decides the result.
- [x] **`true` / `false` literals.** Already lexed (`KW_TRUE`/`KW_FALSE`) and
      parsed (`LITERAL_EXPR`), but `build_hir` didn't handle the `.literal`
      view, so even `if true` was `UnsupportedExpression`. Added
      `ast.LiteralExpr.token()`, a `hir.Expr.bool_const` that lowers to
      `const_i32` (i32 0/1, like comparisons + `!`), and the print arm.
      Verified end-to-end: `if true`/`if false`, `!true`, `n>0 || true`,
      `n>0 && false`. Scoped to boolean/condition contexts — first-class
      `bool` *values* (storable in `let`, returnable, `env.out` → "true"/
      "false") are the next step and need the type-system plumbing below.
      (`none` for optionals is still unrepresented.)
- [x] **First-class `bool` values (return + print).** A `-> bool` function and
      `env.out(<bool>)` now work, so `fn is_even(n: i64) -> bool { n % 2 == 0 }`
      + `env.out(is_even(4))` prints `true`. Added `hir.Type.bool` (→ MIR i32),
      a `hir.Stmt.host_out_bool` that lowers to a value `if` writing the interned
      `"true"`/`"false"` text, `returnsBool`/`exprIsBool` detection (comparison /
      `&&` / `||` / `!` / literal / `-> bool` call) routing `env.out`, and the
      `-> bool` registration path. To do this soundly, lowering now **threads the
      value type** through `lowerIntBlock`/`lowerValueIf` and reads a call's type
      from its callee (both previously hardcoded i64), so a bool body/return
      validates as i32. Verified end-to-end (incl. `env.out(!is_even(3))`,
      bare `env.out(3 > 5)`, value-`if` and `let`-bearing bool bodies; i64
      functions unaffected). **Still out of scope** (the per-local-typing work):
      bool **locals** (`let x = a > 0`) and bool **params** — both now fail with
      a clean `UnsupportedExpression` (guarded) rather than an invalid module.
- [x] **Bool-typed locals (`var x = true`).** A `bool` is a first-class local
      now, not an int. `let`/`var` bindings infer their type from the
      initializer (`bool` for a comparison/`&&`/`||`/`!`/literal/`-> bool` call,
      else i64), the `hir.Expr.local` read carries its type, and codegen's
      `local_get` uses it (was hardcoded i64) so a bool slot is an i32.
      Function locals are materialized from the scope's per-local types instead
      of all-i64. `env.out(x)` of a bool binding prints "true"/"false".
      **A bool is not an int**: assignment is type-checked — `x = 5` on a bool
      (and `bool += …`) is rejected, no int↔bool coercion. Verified: `var x =
      true`, `let flag = 3 > 1`, `var x = true; x = !x` (in a fn), `let even =
      n % 2 == 0` used in `if`, `let r = is_even(4)`. **Known gap (pre-existing,
      type-independent):** `main` itself doesn't support local *reassignment* or
      `while` — that lives in functions today; `var x = true; x = false` works
      in a fn but not directly in `main` (an i64 reassign in `main` fails the
      same way). Bool **params** are still the remaining bool surface.
- [x] **Bool parameters + `main` control flow.** Two follow-ons closing the
      bool surface and the main/function gap:
      • **Bool params.** `fn pick(b: bool, n: i64)` works; params can be bool
        (i32 0/1) as well as i64. Call arguments are type-checked against the
        parameter — an int to a bool param (or vice-versa) is rejected
        (`UnsupportedCall`), no int↔bool coercion.
      • **`main` reassignment + `while`/`if`/`loop`.** `main`'s statement
        builder was generalized (`buildMainStmt`/`buildMainBlock`) to handle
        control flow with bodies that still write the host (`env.out`, `qview`)
        — the function-body builder can't `env.out`. The entry lowering was
        unified with the function-body setup lowering (`lowerEntryStmt` now
        covers assign/while/loop/if/break/continue too). Two supporting fixes: a
        mutable `var` with a constant initializer no longer const-folds (it must
        stay a runtime local), and a const `let` used in a runtime expression
        (e.g. an `if` condition) materializes as its constant value.
      Verified: `var x = true; x = false`, `while i < n { env.out(i); i = i+1 }`
      in `main`, `if`/`else` with a const-`let` condition, a bool-flag loop
      (`while !done { … done = true }`), sum 1..5. 197 unit tests + roundtrips +
      79 CLI tests green.

### The linking ladder (do in order)
0. [x] **DO FIRST.** `q64 emit` now **errors** on constructs it can't compile
       instead of silently embedding them — string interpolation whose value
       isn't a compile-time constant (`UnsupportedInterpolation` /
       `NotConstExpr`) and imports it can't resolve (`UnknownModule` /
       `NameNotFound` / `UnsupportedImport`). `q64/src/codegen/emit.zig`
       `Resolver` + `renderStringLit`; `cmdEmit` reports + exits non-zero.
1. [x] JSON5 manifest parsing in `qube run`/`web` (`qube/src/main.zig`
       `json5ToJson` normalizes the full manifest dialect — `//`+`/* */`
       comments, trailing commas, single-quoted strings, unquoted keys —
       then parses with `std.json` into a `Value`). Unit tests in
       `main.zig` (`zig build test`); the qube-test "full JSON5" case is
       no longer `test.failing`.
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
5. [x] Cross-module calls land **for real**: `env.out(version())` now emits
       `version` as a wasm `() -> (i64, i64)` function returning `(ptr, len)`
       (the v0 string-return ABI) and calls it at runtime — not folded.
       `q64/src/codegen/emit.zig` `ensureCallee` + `emitModule` (action plan
       + Multivalue feature + tuple local). Const-folding remains for
       interpolation (`"{version()}"`). Confirmed: the real form emits two
       functions, the folded form one. Interpolated string *concatenation*
       at runtime (a string builder over linear memory) is the next ABI step.
7. [x] **Memory64 / 64-bit ABI.** Per `spec/memory.md` (Wasm 3.0, 64-bit
       mode), codegen now emits a Memory64 linear memory with `i64`
       pointers; `env.out` is `(i64, i64) -> ()`. `emit.zig` enables the
       Memory64 feature + i64 consts/segment offsets; the wasmtime host
       (`runtime/wasmtime/`) enables `wasm_memory64` on the engine config
       and reads i64 args; `hello.wat` updated to `i64`/`(memory … i64 …)`.
       Verified: emitted memory section flags = `0x05` (has-max + 64-bit).
8. [x] **Scope arena + runtime string concatenation.** First *writable*
       region: a mutable `sp` bump-pointer global starting past the static
       data (`spec/memory.md` §"Region kinds", the implicit `scope` Arena).
       Interpolation containing a call (`"q64 v{version()} ok"`) is now
       built at run time — `emitFn` splits the literal into segments
       (`splitInterpolation`), `emitModule` lowers a `print_concat`:
       bump-alloc the total length, `memory.copy` each const run / call
       result into the buffer, then `env.out` it. Needs BulkMemory(+Opt)
       for `memory.copy`. Pure-constant interpolation still folds.
       Verified end-to-end: `scripts/link-roundtrip.sh` now asserts
       `q64 v0.1.0 ok` (a 3-segment runtime concat). v0 arena has no
       reclamation (single `_start` run, 1 page).
9. [x] **String parameters + argument passing.** A `str` parameter lowers
       to two i64 wasm params (ptr, len); callees are emitted as
       `(i64×2·params) -> (i64, i64)`. v0 bodies are passthrough
       (`fn id(s: str) -> str { s }` returns the parameter); `ensureCallee`
       detects the param-ref body, `emitFn` materializes string-literal
       arguments into the data segment and the `print_callee` call site
       passes them, with an arg-count check. Verified end-to-end:
       `link-roundtrip.sh` asserts `env.out(id("passed")) -> passed`.
10. [x] **Parameterized bodies that transform their arguments.** A callee
       body that interpolates its parameter (`fn shout(s: str) -> str {
       "{s}!" }`) is built in the scope arena and returned. Generalized the
       arena concat into `appendConcat` (used by both `_start` and callee
       bodies); `Segment` gained a `param` variant, `splitInterpolation`
       became parameter-aware, and the callee emits the concat + returns
       `(buf, len)`. `link-roundtrip.sh` asserts `shout("loud") -> loud!`.
11. [x] **Multi-argument functions + composed call arguments** (verified +
       regression-locked; these fell out of the param work). A callee may
       take several `str` params (`fn join(a, b) { "{a}-{b}" }` →
       `join("x","y")` → `x-y`), and a const-foldable call may be passed as
       an argument (`shout(version())` → `0.1.0!`, the inner call folds to
       the argument bytes). Covered by emit unit tests + `link-roundtrip.sh`.
       **Boundary / next:** genuinely *runtime* (non-const) arguments and
       nested non-const calls aren't supported — they need a runtime
       (ptr,len) passed at the call site, which has no consumer until there
       is a non-const string source (e.g. `let` bindings of call results,
       host inputs). After that: the `Stack` region kind (LIFO, freed on
       return) and multi-memory segregation (`spec/memory.md`).
12. [x] **Compile-time `let` / `var` bindings in `main`.** A binding names a
       const-foldable value (literal, const call, const interpolation);
       later statements reference it directly (`env.out(name)`) or in
       interpolation (`"Hello, {name}!"`), and bindings can reference
       earlier bindings. Lives in the resolver: a `bindings` table +
       `constEvalExpr` resolving a `.path` to a bound value; `emitFn`
       records each `let` and folds references. Verified end-to-end
       (`link-roundtrip.sh`: `let name/v` → `Hello, world! (q64 v0.1.0)`).
13. [x] **Runtime `let` bindings — the first genuine non-const values.** When
       a `let` initializer isn't const-foldable (`let g = shout("hi")`), the
       binding holds the call's `(ptr, len)` in two `_start` locals (binding
       locals occupy the front of the frame). References read those locals:
       `env.out(g)` (a `print_binding` action) and `"{g}"` (a `binding`
       concat segment), so a binding can be used many times from one
       evaluation. `_start`'s local layout became
       `[binding i64s][transient tuples][buf/off/len scratch]`; a `bind_call`
       action computes the value. Verified end-to-end (`link-roundtrip.sh`:
       `let g = shout("hi")` → `hi!` / `got: hi! and hi!`).
14. [x] **Runtime arguments.** A runtime binding can now be *passed* into a
       call: `ArgVal` became `constant | binding`, `extractCallArgs` detects
       a bare reference to a runtime binding and passes its locals
       (`local.get ptr/len`) rather than const-folding. This completes the
       value flow — `let g = shout("hi"); let w = wrap(g); env.out("{w}")`
       binds, passes, binds the result, and references it. Verified
       end-to-end (`link-roundtrip.sh`: `wrap(g)` → `[hi!]` / `nested:
       [hi!]`). **Boundary:** the argument must be a binding or a const — a
       *nested* non-const call (`wrap(shout("yo"))`) still errors; bind it
       first. **Remaining `spec/memory.md` work:** the `Stack` region kind
       (LIFO, freed on return) and multi-memory segregation.
6. [x] Codegen: string interpolation `"{expr}"` — `{expr}` is parsed (via
       `parse.parseExpression`), const-evaluated, and concatenated; `{{`/`}}`
       are literal braces. Runtime-valued interpolations error honestly.
15. [x] **Control flow — `if`/`else` in i64 functions.** An i64-returning
       function whose body is an `if`/`else` (or an else-if chain) lowers to a
       wasm `BinaryenIf` yielding i64; each branch's block contributes its
       tail value, recursing for nested ifs. Conditions lower via `emitCond`:
       the comparison operators `== != < <= > >=` become signed i64
       comparisons, and any other i64 expression is truthiness-tested
       (`x != 0`). A value `if` must end in an `else` (every path yields a
       value) or it errors (`UnsupportedCall`). New `emitFn` helpers
       `emitIntBody`/`emitIntBlock`/`emitIfInt`/`emitCond`. Composes with
       bindings, runtime args, and interpolation (e.g. `let m = max(10, 4);
       let c = clamp(m, 7); "max={m}, clamped={c}"`). Verified end-to-end
       (`link-roundtrip.sh`: `max`/`sign`/`abs`/`clamp` → `9 / -1 / 13 /
       max=10, clamped=7`) + emit unit tests. **Boundary:** conditions and
       branches are i64-only (no `bool`/`str` values yet); no loops; in-body
       `let` bindings inside a callee aren't supported (only the tail
       statement contributes the value).
16. [x] **In-function `let`/`var`, `var` reassignment, and `while` loops in
       i64 functions.** i64 callees can now express iterative algorithms.
       `emitIntBlock` walks every statement (not just the tail): in-body
       `let`/`var` declare wasm locals (`emitIntStmt` + a new `IntScope`
       mapping name → local index + mutability), `assign` reassigns a `var`
       (`emitAssignInt`: `= += -= *= /= %=`, signed; rejects `let`/params with
       `ImmutableAssign`), and `while cond { … }` lowers to a test-first
       `block`/`loop`/`br_if(eqz cond)` with unique labels (`emitWhileInt`,
       mirroring `__fmt_i64`'s loop). The i64 emitters thread `*IntScope` in
       place of the flat param-name list; `emitIntBody` returns the body plus
       the extra-local count so the call site declares the `varTypes`. The
       tail still yields the value (expr/`return`/`if`); a block ending in a
       statement with no value errors (`UnsupportedCall`). Verified end-to-end
       (`link-roundtrip.sh`: `sum_to(10)`/`fact(5)`/`poly(3)`/`sum_to(100)` →
       `55 / 120 / 12 / sum_to(100)=5050`) + emit unit tests (incl. the two
       immutable-assign rejections). **Boundary:** still i64-only; no `loop`/
       `for`/range iteration, no `break`/`continue`, no loops or in-body
       bindings in `main` (the `_start` body uses the resolver path), and no
       calls inside `emitIntExpr` (`fn g(n){ f(n)+1 }` stays `NotConstExpr`) —
       these are the next rung.
17. [x] **Calls inside i64 functions — composition + recursion.** `emitIntExpr`
       gained a `.call` arm: it lowers `f(args…)` to a `BinaryenCall` returning
       i64, with each argument lowered as an i64 expression. So an i64 function
       can call any i64 function — including itself (`fact`/`fib`/`gcd`) and
       mutually (`is_even`/`is_odd`) — and compose helpers (`hyp_sq` →
       `square`). A pre-emission pass (`registerCalls`/`…Block`/`…If`/`…Expr`
       in `emitFn`, before `emitModule`) walks each i64 callee body and
       `ensureCallee`s every call site, so transitively-reached functions are
       registered + emitted; index-based iteration + name dedup makes it a
       terminating fixpoint, and the captured `FnDecl` is a stable CST pointer.
       The registered callees ride on `IntScope.callees` so the `.call` arm
       resolves a target by name (validating it's an `int_fn` and that the arg
       count matches `n_params`). Self/forward/mutual references resolve by
       name at module finalization. Verified end-to-end (`link-roundtrip.sh`:
       `fact(6)`/`fib(10)`/`gcd(48,36)`/`hyp_sq(3,4)` → `720 / 55 / 12 / 25`) +
       emit unit tests (incl. arg-count and non-i64-callee rejections).
       **Boundary:** a call resolves only to a function in the symbol table —
       an imported name or a local function in the same file. Calling a
       dependency's *non-imported* / private helper still errors
       (`NameNotFound`); that wants the name-resolution pass. Also still no
       `loop`/`for`/range, no `break`/`continue`, and no loops or in-body
       bindings in `main`.
18. [x] **`break` / `continue` / early `return` / `loop` in i64 functions.**
       The i64 body emitters now lower the full control-flow set, so loops can
       exit early and iterate with skips. `IntScope` gained a loop-label stack
       (`loops` + `topLoop`); `emitWhileInt`/`emitLoopInt` push the (exit,
       re-enter) labels around the body. `emitIntStmt` gained arms for
       `break`→`br $exit`, `continue`→`br $reenter`, early `return`→
       `BinaryenReturn`, a statement-position `if` (`emitVoidIf`, `none`-typed,
       branches may break/continue/return), and `loop { … }` (`emitLoopInt`:
       `block $b { loop $l { <body>; br $l } }`). A `loop` as a function's
       value tail diverges — `emitIntBlock` emits it then an `unreachable` so
       the block still types i64 (it must exit via `return`). `break`/
       `continue` outside any loop error (`BreakOutsideLoop`); value-carrying
       `break x` is rejected for v0. Verified end-to-end (`link-roundtrip.sh`:
       `first_factor(15)`/`first_factor(49)`/`is_prime(13)`/`is_prime(9)`/
       `sum_odd(10)`/`count_to_sum(10)` → `3 / 7 / 1 / 0 / 25 /
       count_to_sum(10)=4`) + emit unit tests (incl. break/continue-outside-
       loop rejections). **Boundary:** still i64-only; no `for`/range iteration
       (range expressions don't parse yet — `0..n`), no value-`break`, and no
       loops or in-body control flow in `main` (the `_start` resolver path).

**Definition of done met.** `cd examples/link-demo/hello_app && qube run`
prints `0.1.0` by linking `dev.q64.hello_world` (a local-path dependency)
and calling its `version()`. Durable regression test:
`scripts/link-roundtrip.sh` (covers `q64 emit --module` *and* `qube run`) +
`examples/link-demo/`.

The long pole — a real (non-const-folded) cross-module call — is **done**
(step 5 above). `scripts/link-roundtrip.sh` now exercises the real call.
Next on the codegen path: callees with parameters (the AST shape is ready;
needs argument passing + a memory/stack convention) and runtime string
concatenation for interpolation.

### Deferred package bits (not compiler; pick up anytime)
- [x] `qube.lock` — specced (`spec/qube.lock.md`: format v1, deterministic
      JSON, PKG010–PKG013) and implemented: `qube add` upserts an entry,
      `qube lock` regenerates from the manifest (reusing satisfying locked
      versions; resolves caret/exact ranges against registry metadata, no
      archive download), and `qube run`/`build`/`web` resolve a registry
      dep **only** via lockfile → sha256 → `~/.qube/cache` → `--module`
      (never the network). Verified end-to-end: a cached registry dep
      links and runs; PKG01x paths covered in `add-remove.test.ts`;
      renderer/semver unit tests in `main.zig`.
- [x] `qube install` — relocks when qube.lock is missing/stale
      (`lockSatisfiesManifest`), then fetches every locked registry
      archive the cache is missing (shared `downloadAndCacheArchive`
      with `add`). `--offline` turns a needed relock into PKG010 and a
      cache miss into PKG012. Hermetic CLI tests in `install.test.ts`.
- [x] `capabilities` is generated, not authored: `qube publish` derives
      the set from `q64 show capabilities` (effect→capability table in
      `qube.json5.md`) and rewrites the manifest field in place before
      packing; a non-compiling qube refuses to publish (exit 64); the
      registry's ENV040/ENV041 check is reframed as a backstop across
      `qube.json5.md` / `env.md` / `qube-cli.md` / `continuum-api.md`.
- [ ] `--frozen` / `--locked` flags; `add` dedup.
- [ ] `qube publish` clean-release-build check (`qube-cli.md` publish step 4) — blocked on compiler.
- [ ] `qube remove` / `outdated` still stubs.

### Notes for the next agent
- Build with the **vendored** zig: `vendor/zig/zig build` (homebrew zig at
  `/opt/homebrew/bin/zig` has different `std.Io` APIs). The login command had
  stale `takeDelimiterExclusive`/`readAllAlloc` calls fixed this session to
  match the pinned zig — watch for the same drift elsewhere.
- Deploy the registry: `cd continuum-api && CLOUDFLARE_ACCOUNT_ID=<your-account-id> pnpm run deploy` (needs `wrangler login`).
- Registry auth is a pre-OAuth dev bypass at `POST /v1/auth/token`; credentials are set per-deploy via `BYPASS_EMAIL` + `BYPASS_PASSWORD` env vars (bypass returns 503 if either is unset). Route lives in `continuum-api/src/routes/auth.ts`; delete when OAuth lands.

## Q64 IR — two-tier backend-neutral IR (HIR/MIR) — ACTIVE

Honoring the decision that semantics must not depend on a backend's IR. We
lower to our own IR first: **HIR** (Semantic QIR) → **MIR** (Executable QIR) →
Binaryen/WASM, with a future `MIR → LLVM → native` backend an additive change.
Full design + phasing in the approved plan
(`/root/.claude/plans/question-the-important-design-purring-beacon.md`) and
[`q64/src/ir/README.md`](./q64/src/ir/README.md). Migrates incrementally behind
a per-construct router in `codegen/emit.zig` (legacy `AST → Binaryen` is the
fallback); `Q64_IR_STRICT=1` panics on fallback to track coverage. MIR control
flow is **structured** (wasm-shaped) with an explicit **CFG escape hatch**:
`mir.Func.body` is `Body = structured | cfg`, the `cfg` arm (`BasicBlock` +
`Terminator`) reserved for a future relooper/LLVM backend (WASM backend rejects
it with `CfgUnsupported`).

- [x] **P0 scaffold + P1 literals.** `q64/src/ir/` package: `hir.zig`/`mir.zig`
      (pure Zig, no Binaryen), `build_hir.zig` (AST→HIR), `lower.zig` (HIR→MIR),
      `print.zig` (dumps). Wired into `build.zig` (`ir_mod` + `ir_tests`).
      `emitFromSource` routes `fn main` of `env.out("<const string>")` through
      `AST→HIR→MIR→Binaryen` (`lowerToWasm`/`lowerInst`); everything else falls
      back to legacy. Verified: 169/169 unit tests (7 new IR tests),
      `link-roundtrip.sh` green, and `Q64_IR_STRICT=1` runs literals / panics on
      interpolation as designed. ARCHITECTURE.md updated (pipeline + `ir` stage).
- [x] **P2 i64 + control flow.** `build_hir` transcribes i64 functions (params,
      in-body `let`/`var` with index assignment, compound-assign desugaring) +
      the callee fixpoint (recursion reserves params before the body so arity
      checks pass); `lower` ports the `emitIntBlock` tail/control-flow logic
      (value vs void `if`, `while`→loop, diverging `loop`+`unreachable`) into
      structured MIR (`if_`/`while_`/`loop`/`br`/`br_cont`/`ret`); the backend
      `Lowerer` expands those with a label stack + emits multi-function modules,
      `__fmt_i64`, the arena `sp` global, and the pair scratch local. `lower`
      returns `Unsupported` for not-yet-handled shapes → router falls back.
      Verified with `Q64_IR_STRICT=1`: `fact`/`fib`/`gcd`/`sum_to`/`first_factor`/
      `sum_odd` → `720/55/12/5050/7/25` all through AST→HIR→MIR→Binaryen;
      170/170 unit tests + link-roundtrip.sh green.
- [x] **P3a compile-time strings.** `ir/consteval.zig` (ported from the legacy
      `Resolver`): folds const string interpolation, integer arithmetic, const
      `let` bindings, and const-bodied nullary calls — the last only in a `let`
      initializer (`fold_calls`), matching "direct `env.out(f())` is a real
      call." `build_hir` evaluates `main`'s `let`s into evaluator bindings and
      folds const `env.out` args to `host_out` (str_const) — reusing P1's data
      path, no MIR/backend changes. Verified via `Q64_IR_STRICT=1`:
      `"{(1+2)*3} {n+1} {1_000+24}"`→`9 43 1024` and `let name/v` + interpolation
      → `Hello, world! (q64 v0.1.0)` route through the IR; 172 tests + roundtrip
      green.
- **P3b runtime string ABI** (in progress). The `(ptr,len)` ABI in MIR
  (`ValueType.str` = a pair; backend realizes it as a two-i64 multivalue).
  - [x] **P3b-1 str-returning const functions + `env.out(str_call)`.** MIR gains
        `str_const_val` (→ `TupleMake`) and `host_out_str` (store pair, extract,
        env.out, newline); a str fn returns `pair_type`; the call-result type
        comes from the callee's `ret`. `build_hir` registers str functions
        (`registerStrFunc`, nullary, const-literal body) and routes a str-call
        `env.out` arg to `host_out_str` (`isStrCall`); `buildIntExpr` now rejects
        a str callee in an i64 context. Verified `Q64_IR_STRICT=1`: the link-demo
        `env.out(version())` → `0.1.0` through AST→HIR→MIR→Binaryen.
  - [x] **P3b-2** str params + passthrough (`id(s){s}`), str-literal/const-call
        args. MIR `str_param` (→ `TupleMake` of locals `2·idx`,`2·idx+1`); the
        backend expands a str param into two i64 wasm params and a str argument
        into two i64 operands (`strOperands`). `build_hir` registers all-str-param
        str functions; `buildStrArg` folds a const arg (`id(vshout())`) or passes
        a parameter through. Verified `Q64_IR_STRICT=1`: `id("passed")`→`passed`,
        `id(vshout())`→`0.1.0`.
  - [x] **P3b-3** concat / interpolation. MIR `str_concat` ([]piece); the backend
        `emitConcat` ports the legacy `appendConcat` (call pieces → tuple slots,
        sum lengths, bump `sp`, `memory.copy` each), yielding `(buf,len)`. Per-
        function scratch layout (`scanScratch` → tuple slots + buf/off/len) for
        both entry and callees. `build_hir.buildConcat` splits an interpolation
        into const-run / param / nullary-call pieces (folding const interps).
        Verified `Q64_IR_STRICT=1`: `"q64 v{version()} ok"`→`q64 v0.1.0 ok`,
        `shout("loud")`→`loud!`, `join("a","b")`→`a-b`, `shout(version())`→`0.1.0!`.
  - [x] **P3b-4** runtime str `let`/`var` bindings + runtime args. MIR `str_bind`
        (split a str value's (ptr,len) into two locals) + `str_binding` (read
        them); `emitConcat`/`strOperands` gained a `str_binding` piece/operand.
        `build_hir` tracks `main`'s runtime str bindings (`main_rt`) + their
        backing locals (`main_locals`), threaded as an `rt` scope through the str
        builders so `{g}`, `env.out(g)`, and `wrap(g)` resolve. Fixed: `lower`
        now carries the entry's `locals` into MIR. Verified `Q64_IR_STRICT=1`:
        `let g = shout("hi"); env.out(g); "{g} and {g}"; let w = wrap(g); "{w}"`
        → `hi!` / `got: hi! and hi!` / `nested: [hi!]`.
  - [x] **P3b-5** i64 bindings + int interpolation in `main`. The HIR builder
        tracks `main`'s runtime i64 `let` bindings in the shared local space
        (str bindings take two slots, i64 one), resolves later references and
        `{a}` interpolation pieces (`fmt_int(local#N)`), and `lower` emits a
        `local_set` in `_start` + `fmt_int_to_str` inside `str_concat`; the
        backend's entry scratch layout already sits past `f.locals`. Verified
        end-to-end `Q64_IR_STRICT=1`: `let a = double(21); env.out(add(a, 8));
        let b = add(a, 8); let g = shout("hi"); env.out("{g}: a={a}, b={b}")`
        → `50` / `hi!: a=42, b=50` through AST→HIR→MIR→Binaryen, no fallback.
        Locked in: `build_hir`/`lower` unit tests + a dedicated strict assertion
        in `link-roundtrip.sh`.
  **After P3b: done.** The *entire* `link-roundtrip.sh` corpus now emits with
  `Q64_IR_STRICT=1` and zero fallbacks — every program (literals, str ABI, i64
  fns + control flow + recursion + loops, and now main-level i64 bindings +
  interpolation) runs through the IR. This is the threshold for **P4 (delete
  legacy)**: the router never falls through for the covered corpus.
- **P4 delete legacy** (in progress).
  - [x] **P4a unblock — the router no longer falls through.** The IR path now
        owns the honest-baseline diagnostics that only the legacy emitter
        produced before (`hir.Reject` + `build_hir.Result`; codegen `mapReject`
        → the same `Error` codes: NoMainFunction / UnsupportedCall /
        NameNotFound / NotConstExpr / ImmutableAssign). `consteval` splits
        `ConstArith` (all-const but invalid: div-by-zero/overflow → NotConstExpr)
        from `NotConst` (needs a runtime value → fall back). Closed the one
        success gap (untyped fold-only helper in interpolation) and scoped
        `buildScreenFuncs` to the public surface. Verified **strict-clean across
        the whole test surface**: 180/180 zig unit tests, `link-roundtrip.sh`,
        and 74/74 `q64-test` CLI tests under `Q64_IR_STRICT=1` (zero fallbacks).
        Legacy is now unreachable for the corpus.
  - [x] **P4b delete.** Removed `emitFn`/`emitModule`, the
        `Action`/`Segment`/`ArgVal`/`RtBinding` model, the legacy int/concat
        emitters (`emitInt*`/`appendConcat`/`splitInterpolation`/`ensureCallee`/
        `IntScope`/…), and trimmed the `Resolver` to import-resolution + `lookup`
        (dropped its const-eval machinery + the `bindings` table). Kept the
        shared `emitFmtI64` / `binOp` / `LoopLabels` / `findPublicFn` /
        `emitHelloWasm`. `emitFromSource` is now IR-only: a null from `tryIrEmit`
        (genuinely unsupported, e.g. faces/streams) is an honest
        `UnsupportedExpression`; the `Q64_IR_STRICT` coverage gate is gone (no
        fallback to gate). **emit.zig: 3854 → 1777 lines.** Re-verified green:
        180/180 unit tests, `link-roundtrip.sh`, 74/74 `q64-test` CLI tests.
        ARCHITECTURE / `ir/README` updated to "IR is the sole emission path".
- **P5 introspection + tail seams.**
  - [x] **`q64 show hir|mir`.** New `show` subcommand dumps either IR tier as
        text to stdout (takes the same `--module name=dir` flags as `emit`);
        shares `emit`'s front (`buildHir`: parse → resolve → build HIR), so a
        malformed program surfaces the same honest diagnostic on stderr +
        non-zero exit. `emitFromSource` was refactored onto `buildHir` (and the
        interim `tryIrEmit` removed). Specced in `q64-cli.md`; covered by
        `q64-test/tests/show.test.ts` (5 CLI tests) + an IR unit test.
  - [x] **HIR visibility slot surfaced.** `show hir` prints `pub` for a
        non-entry public function (an exported screen/twin handler) — the
        export-surface signal the component/WIT lift will read.
  - [x] **Effect slot + effect pass.** `hir.Func` carries an `effects` field —
        the capability set (`hir.Effect`, spec/effects.md) inferred by a new
        pure-Zig HIR pass (`ir/effects.zig`). It walks each function's body for
        host faces (`env.out` → `@stdout`, a `qview.*` host call → `@ui`), unions
        callee sets up the call graph to a fixpoint (handles recursion/cycles),
        closes implications (`@stdout` ⇒ `@io`), and writes the sorted set back.
        Runs inside `build_hir.tryBuild`, so every consumer sees effect-annotated
        HIR. `show hir` now prints the set on each function's header line
        (`fn main -> void [entry] @stdout + @io`). Verified: effects.zig API
        tests (`implies`/`marker`/`witImport`/`close`) + build_hir integration
        tests (stdout/ui/pure-helper) + `show effects` CLI test.
  - [x] **Component/WIT lift seams — `show effects|capabilities|world`.** Three
        new `show` kinds over the effect-annotated HIR (spec/q64-cli.md): `show
        effects <fn> --qube <file>` prints one function's set; `show capabilities
        --qube <file>` prints the qube's capability closure over its public
        surface; `show world --qube <file>` synthesizes the WIT `world` — exports
        = the public surface (signatures lowered to the canonical ABI via the
        `witType` map), imports = the capability set mapped through the
        effect→WIT-import table (`hir.Effect.witImport`: `@stdout` →
        `wasi:cli/stdout`, `@ui` → `q64:host/ui`, …). `--qube` flag added to
        `cmdShow`. Flipped `show/types-effects.test.ts` (effects) and
        `show/capabilities-world.test.ts` (capabilities, world) from `test.failing`
        to passing; 80/80 CLI tests + roundtrips green.
  - [x] **Dependency-origin visibility / unreached `pub` surface.** The HIR
        builder now constructs the qube's **full public surface**, not just the
        `main`-reachable graph: `buildScreenFuncs` walks every non-`main` top-level
        `pub fn` and builds it — void-returning ones as screen/twin handlers (as
        before), value-returning ones (`pub fn greet(name: str) -> str`) via
        `registerFunc`. Each is marked `.public`, which also **upgrades a local
        `pub fn` that `main` already built `.private`** to a public export; a
        transitively-reached *dependency* function (declared in another file) never
        reaches this pass, so it correctly stays `.private` — scoping the export
        surface to the qube being compiled. `show world`/`show effects <fn>` now
        see unreached exports (the `NameNotFound`/omission boundary is gone), and a
        **main-less library qube** (only `pub fn`s) builds + emits instead of being
        rejected `NoMainFunction`. Verified: 3 build_hir surface tests
        (unreached export, reached→public upgrade, main-less library) + a `show
        world` library CLI test; 81/81 CLI tests + roundtrip green.

## Component emission — `q64 emit --component` — ACTIVE

Wiring the WIT lift into a build artifact: a real WebAssembly **component**
wrapping the core module (spec/modules.md §"The qube as a component",
spec/q64-cli.md `--component`).

- [x] **Smallest faithful slice — validated by wasmtime.** `q64 emit <f> <out>
      --component` writes the core module *and* `<out>.component.wasm`, a genuine
      component the vendored wasmtime accepts, instantiates, and can call.
      - `codegen/component.zig` — a pure-Zig component-model binary encoder
        (preamble + core-module / core-instance / alias / type / canon-lift /
        export sections). `emit.emitComponent` emits the core module, checks it
        is import-free, gathers the scalar `pub` surface, and wraps it.
      - **Scope:** import-free core modules, **scalar** exports (`i64`→`s64`,
        `bool`, `f64`) that cross the canonical ABI with no memory/`realloc`
        glue. A `str`/list export is skipped; a core module that imports a
        capability face (`env.out`) is `ComponentNeedsImportLowering` (honest,
        not mis-wrapped); an empty liftable surface is `ComponentNoExports`.
      - **Two supporting codegen fixes:** the `env.out` import is now declared
        only when used (`usesEnvOut`) — a pure library imports nothing; and a
        public value-returning callee is now `exported` by name (was only set on
        the entry/screen path), so a library's functions reach the host + lift.
      - **Validation harness:** `runtime/wasmtime/src/component_check.zig` →
        `q64-component-check`, which runs `wasmtime_component_new` (validate) and
        optionally instantiates + calls a scalar export. `scripts/component-
        roundtrip.sh` (+ `zig build component-roundtrip`) proves `add(2,3)=5`,
        `mul(6,7)=42`, `sub(50,8)=42` through real components, and asserts the
        boundary rejections. Plus `component.zig` structural unit tests.
- [x] **`qube build --component` delegation.** `qube build [--component]
      [--addr wasm32|wasm64] [--release]` (`qube/src/main.zig` `cmdBuild`) reads
      the manifest, resolves deps to `--module` specs, and delegates to `q64
      emit` — writing `target/<profile>/<addr>/<name>.wasm` and, with
      `--component` (flag or manifest `component.emit: true`),
      `<name>.component.wasm`. Builds libraries as well as apps; doesn't run the
      result. New `examples/math-lib/` (a scalar library that lifts cleanly).
      Verified: `qube-test/tests/build.test.ts` rewritten to real compiles
      (gated on `q64Available`, `Q64_BIN` threaded through) + `usage`/`exit-codes`
      pins updated; `scripts/component-roundtrip.sh` now also drives `qube build
      --component` on the example and validates with wasmtime. 113/113 qube-test
      + 81/81 q64-test green. **Remaining:** `--target <name>` (named manifest
      targets) is accepted-but-ignored, not yet wired.
- [x] **App → WASI command component (`wasi:cli/run` + `wasi:cli/stdout`), run
      under WASIp3.** `q64 emit --component --addr wasm32` on an app that writes
      stdout emits a WASI **preview1 core module** — `env.out` lowered to a
      `wasi_snapshot_preview1.fd_write` import (an iovec written to fd 1,
      `emit.StdoutAbi.wasi_preview1`) — and runs `wasm-tools component new
      --adapt` with the vendored WASI adapter (`vendor/wasi/`) to lift it into a
      `wasi:cli/run` command that imports `wasi:cli/stdout`. The CLI drives the
      shell-out (`q64`'s `main.adaptPreview1Component`; tools resolved via
      `Q64_WASM_TOOLS` / `Q64_WASI_ADAPTER`, else repo `vendor/`, else `PATH`),
      so `codegen/` stays free of subprocess concerns. `q64 show world` names the
      same world (`import wasi:cli/stdout; export wasi:cli/run`). Verified
      **end-to-end**: the app is run with the vendored **wasmtime CLI** under the
      async WASIp3 runtime — `wasmtime run -S p3` — and
      `fn main { env.out("Hello, q64.") }` prints `Hello, q64.`;
      `examples/hello-component` builds + runs via `qube build --component --addr
      wasm32`. `component-roundtrip.sh` asserts the WASI world (via `wasm-tools
      component wit` *and* `q64 show world`) and the `-S p3` run. The retired
      hand-rolled `log`-face indirection encoder (`component.encodeApp`,
      `emit.buildShimModule`/`buildFixupModule`) is gone.
      - **WASI-version reality (important).** The CLI command world is
        **`wasi:cli@0.2.x`** — there is *no* `wasi:cli@0.3` upstream (even the
        wasi-cli `v0.3.0-rc-*` tags declare `package wasi:cli@0.2.7`). "WASIp3 /
        0.3" is the async **`wasi:io@0.3`** layer (native `stream`/`future`,
        retiring the poll/streams resource ceremony) plus the component-model
        async ABI — *not* a `wasi:cli` version bump. So `wasi:cli/run@0.2.x` is
        the correct, only command world; it is **not** a "Preview 2 fallback".
      - **Runner = the wasmtime CLI.** The embedded wasmtime **C API** only
        implements WASIp2 (`add_wasip2`, no `add_wasip3`); the **CLI** has `-S
        p3`. So `init.sh` now also vendors the wasmtime CLI binary
        (`vendor/wasmtime/bin/wasmtime`, sha256-pinned) as the WASIp3 runner, and
        `q64-component-check` is back to validate-only + scalar-call (no app
        run).
      - **Scope:** wasm32 only (preview1 is 32-bit); the `@stdout` capability.
      - **Follow-on:** **async-native `wasi:io@0.3` stdout emission.** Today the
        emit path uses the preview1 adapter → synchronous `wasi:io/streams@0.2.x`
        (the resource ceremony WASIp3 retires). Emitting genuinely async I/O
        means async canonical-ABI codegen (wit-bindgen-async-style import of the
        0.3 stream write) — no adapter shortcut exists. That's the next slice;
        the runtime is already p3 via `-S p3`. Plus multiple capabilities
        (`@fs`, `@time`, …).
- [ ] **String / list exports.** Lift `str`-returning / `str`-param exports via
      the canonical ABI string representation (memory + realloc canon options);
      today they're skipped from the component surface.

- [ ] **Later: native via LLVM.** A `codegen` sibling lowering `MIR → LLVM IR`,
      plus a native host ABI for the `env.*` capability faces (the one piece not
      inherited from the WASM component model).
      **Decision recorded (2026-06): direct `MIR → LLVM IR`, no MLIR layer.**
      HIR→MIR already is the multi-level lowering MLIR would provide; the
      last hop is the *easy* direction (structured MIR → basic blocks is the
      same label-stack walk the Binaryen `Lowerer` does — no relooper; the
      `mir.Body.cfg` escape hatch isn't even needed for it), and MLIR's cost
      (a huge C++ dep on a pure-Zig compiler, C API hostile from Zig, a third
      IR) buys nothing at one CPU target. First rung when this activates:
      emit **textual `.ll`** (zero link deps — data image as a global byte
      array, `sp` global, structured-walk block emission, faces as `declare`d
      externals; system `clang`/`llc` consume it), upgrade to the LLVM C API
      later if warranted. The genuinely hard part is the native `env.*` host
      ABI shim, not the lowering. Pin down the value-add vs `wasmtime
      compile` (Cranelift AOT already runs the components natively) before
      building. Revisit MLIR only if Q64 grows multi-target (GPU) or its own
      mid-level optimization passes — and then as HIR/MIR *as dialects*, not
      a layer on top.

## Semantic pass + struct values → static fits — NEXT (the slope-changing ladder)

Context (coverage audit, 2026-06-11): the compiler emits 18 of 212 specced
diagnostic codes; semantics sit on the `i64/i32/f64/str/bool/ptr/void` floor in
`hir.zig` with ad-hoc typing inside `build_hir`. The TYP band (70 codes — the
largest), structs, optionals, `match`, faces/fits, generics, and the deferred
`PAR040` all queue behind one missing layer: a real semantic pass between AST
and HIR. Same treatment as the IR ladder: explicit rungs, each end-to-end
verified, honest diagnostics throughout.

### Ladder A — semantic pass (name resolution + type checking)

- [x] **A0 — placement decision + scaffold.** `q64/src/sema/` landed:
      README records the pass placement (parse → sema → build_hir; sema
      imports `parser` only, additive until A3), `symbols.zig` builds the
      file-level symbol table (items + selective/namespace import bindings,
      first-binding-wins lookup, collisions recorded for the A1 NAM005
      wiring; `fit`s listed but deliberately not name bindings — they key on
      the (type, face) pair), and `q64 show symbols <file.q>` dumps it
      (specced in q64-cli.md; covered by sema unit tests + a show.test.ts
      CLI test). Emit path untouched. Verified: 278 unit + 76 CLI tests +
      link-roundtrip green.
- [ ] **A1 — symbol table + scopes.** In progress; the core slice landed:
      - [x] Import bindings complete: selective names, `as` aliases (new
            `ast.ImportStmt.alias()` accessor), namespace imports binding the
            last path segment — all with offsets for diagnostics.
      - [x] **NAM005 emitted** for import-involving collisions, wired into
            `q64 check` (parse + sema file-level pass). Conformance:
            `modules/import-collision.q` passes (11/45, from 10/44);
            check.test.ts covers the envelope. Decl-vs-decl duplicates have
            no specced code and stay recorded-only.
      - [x] Body-level resolution (`sema/resolve.zig`): lexical scope stack
            (params, let/var-after-initializer, block nesting, for/match/
            if-let pattern bindings via recursive IDENT_PATTERN collection),
            ambient hosts (`env`/`qview`/`ctx`) recognized, unresolved path
            heads *recorded* and surfaced by `q64 show symbols` — emission
            stays with build_hir until A3 (no double-diagnosis).
            v0 boundaries: interpolation refs (raw string tokens) and
            `screen` bodies are invisible to the walk.
      - [ ] Import-target resolution against `--module` sources (NAM001 /
            NAM006 at the sema layer).
      - [ ] `PAR040` re-land on name kinds (generic-call vs
            chained-comparison — the reverted parser heuristic, see "Other
            open items").
      - [x] Fit registry (`sema/fits.zig`, on B3's structured grammar):
            classifies faces single- vs multi-param by the mechanical
            spec/faces.md rule (any `self` method → single; methods but
            no `self` → multi; prelude faces all single), registers fits
            keyed (target, face) with a `find()` for B4 dispatch, and
            emits **TYP201/TYP202** on the wrong written form. Wired
            into `q64 check` + catalog. Conformance **18 → 20 of 48**
            (both `faces/wrong-fit-form-*.q` flip); 4 sema unit tests +
            a check.test.ts envelope case (79 CLI tests). Unknown
            (cross-module) faces stay silent — the NAM story.
- [x] **A2 — type representation (core).** `sema/types.zig`: an interned,
      structural `TypeStore` — the builtin tower (i8…i128/u8…u128/f16…f64/
      bool/str/void per `spec/types.md`), named types resolved against the
      symbol table (struct/enum/alias/face/imported; a *value* symbol in
      type position is `.unresolved`), optionals, refs, slices, arrays,
      tuples (`()` normalizes to void). Generic args ride along as raw
      text (structured generic args are still a parser item); fn/dyn/union
      stay `.unparsed`. `collectSignatures` lowers every top-level fn
      signature (missing `-> T` = void); `q64 show symbols` renders them
      (`pub fn greet (str) -> str`). Unresolved type names are recorded,
      not emitted — the A4 TYP wiring reads them. Remaining for A2-final:
      structured `fn` types (needed for closure params) + struct field
      shapes (lands with B2). Verified: 287 unit / 77 CLI / 11-of-45
      conformance / link-roundtrip green.
- [ ] **A3 — `build_hir` consumes sema.** In progress:
      - [x] **Signature lowering goes through sema.** `ir` now imports
            `sema` (one-directional, per the sema README plan); the
            `typeNamed` text-matching family (`returnsStr/Bool/I64`,
            `paramIsStr/Bool/I64`) is deleted, replaced by one
            `semaScalar` query: annotation → `sema.types.lower`
            (null table: builtins resolve, named stay unresolved — exactly
            the scalar floor) → mapped onto `hir.Type`, with everything
            beyond the floor staying the honest `Unsupported`. Verified
            byte-stable: 287 unit / 77 CLI / 11-of-45 conformance /
            link-roundtrip — all identical before and after.
      - [x] **Expression typing owned by sema.** `sema/exprtype.zig`:
            `scalarOf` types expressions at the scalar floor (literals,
            the boolean/arithmetic operator tables — moved verbatim from
            `isBoolOp` — paren/unary recursion, call returns, locals)
            behind an injected `Env` (localType/callRet callbacks, same
            pattern as `hir.ModuleResolver`, since the local scope still
            lives in build_hir's wasm-slot bookkeeping). build_hir's
            `exprIsBool` is now a thin `== .bool` bridge; `isBoolOp` and
            `isBoolCall` deleted; all seven call sites untouched.
            Byte-stable: 289 unit / 77 CLI / 11-of-45 / roundtrip — all
            identical.
      - [x] **Name lookup lives in sema.** `sema/link.zig`: the codegen
            `Resolver` moved wholesale as `Linker` (root-fn indexing,
            `--module` import resolution, `findPublicFn`, the honest
            UnknownModule/NameNotFound/UnsupportedImport trio — mapped
            back onto the stable emit codes at the one call site).
            emit.zig's Resolver + findPublicFn deleted; `ModuleSource` is
            now an alias of `sema.link.ModuleSource`; the
            `hir.ModuleResolver` injection stays (ir never imports
            codegen). Byte-stable: 291 unit / 77 CLI / 11-of-45 /
            roundtrip identical.
      **A3 is structurally done**: build_hir consumes sema for signatures,
      expression types, and name lookup. What remains is *ownership of
      body scopes* (the Env bridge in build_hir adapts its wasm-slot
      Scope) — that collapses when the sema check pass lands with A4.
- [ ] **A4 — first real TYP codes + sema-emitted NAM.** In progress:
      - [x] **The check pass + TYP051/TYP042 emitted.** `sema/check.zig`:
            the first sema layer that *emits* — walks fn bodies with
            sema's own typed scopes (params from lowered signatures,
            `let` bindings from annotations — new `ast.LetStmt.type_()`
            accessor, the annotation was already parsed structured — or
            inferred initializers; bare int literals stay *flexible* so
            `a + 1` never false-fires). Emits **TYP051** (provably-integer
            `if`/`while` condition) and **TYP042** (arithmetic mixing two
            different known numeric types), both wired into `q64 check`
            and the diag catalog. Conformance **11 → 13** of 45
            (`types/int-as-bool.q`, `types/numeric-mismatch-no-implicit.q`
            flip; zero golden regressions); q64-test's TYP042
            `test.failing` flips to passing + a TYP051 case (78 CLI
            tests); link-roundtrip PASS (emit path untouched).
      - [ ] **NAM010 deferred — documented.** The corpus survey
            (`show symbols` over spec/tests + fixtures + examples) shows
            systematic false positives from not-yet-parsed forms: lambda
            params, `graph`/`channel` exprs, named args (`capacity: 16`),
            record-pattern fields, auto-prelude names (`sleep`). Unknown
            heads stay recorded-only until those land + an auto-prelude
            name table exists.
      - [x] **Four more codes: TYP040 / TYP041 / TYP050 / TYP060.** One
            shared `checkAgainstExpected(expected, value)` covers both
            declared-type sites — call arguments (against this file's
            lowered signatures; unknown callees silent) and annotated
            `let` initializers: TYP041 (two different known numerics),
            TYP050 (bool where integer expected), TYP051 (integer where
            bool expected — literals are definitely integers, so they
            fire here even though they stay flexible for TYP041/042).
            TYP040 checks bare/negated literal initializers against the
            annotated width (dec/hex/oct/bin, `_` separators, saturating
            u128 parse; i8…u128 bounds incl. `-129`-style negatives).
            TYP060 fires on a flattened [mode-kw, `:`] token prefix in a
            call argument — judged on tokens, not node shape, because
            recovery degrades `ref:` into a unary-expr wrapper.
            Conformance **13 → 17 of 47** (int-literal-out-of-range +
            mode-keyword-in-call flip; new `bool-as-int.q` +
            `call-arg-numeric-mismatch.q` fixtures pass; INDEX rows
            filled); 300 unit / 78 CLI / roundtrip green.
      - [x] **TYP061 specced + emitted (arity).** types.md gains the row
            ("wrong number of call arguments"; generic-arg count stays
            TYP100); catalog entry; check emission against this file's
            signatures. Guarded by an argument-list **well-formedness
            check** (`( ARG (, ARG)* ,? )` exactly): parse recovery
            degrades unsupported forms — record literals, `ref:` — into
            back-to-back CALL_ARGs, which would misalign per-arg checks
            and inflate the count (caught as a golden regression on
            library-face-fit.q before the guard; per-arg TYP041/050/051
            now also gated on it). Conformance 17 → 18 of 48.
      - [x] **Auto-prelude name table** (`sema/prelude.zig`): the
            identifier-shaped rows of modules.md §"The auto-prelude",
            kind-classified (type/face/value). Wired into resolve.zig
            (prelude heads no longer record as unknown — `sleep`,
            `channel`, policy names) and types.zig lowering
            (`Vec<f32>`/`Signal<…>` → `.named{.prelude}` instead of
            `.unresolved`). The *transitive* prelude (capability-face
            signature types: `Url`, `Response`, …) is computed-not-
            curated and waits for loadable stdlib faces.
      - [ ] NAM010 / unresolved-type emission — still blocked on parser
            gaps (lambdas, graph/channel exprs, named args, record
            patterns, generic-param scoping), per the survey; the
            prelude table removed its share of false positives
            (corpus unresolved heads down, all remaining are parser-gap
            forms).

### Ladder B — struct values → static fits (after A3)

- [x] **B1 — record literal expressions.** `Point { x: 1, y: 2 }`,
      shorthand `Color { r }`, empty `DemoTools {}` all parse
      (RECORD_EXPR/RECORD_INIT + ast views; `Expr.record`). The
      disambiguation rule is implemented and recorded in `grammar.md`
      §Expressions: in the bare head of `if`/`while`/`for`/`match` (and
      an if-let RHS), `Path {` opens the statement's block —
      parenthesize to force the literal; parens/brackets/args lift the
      restriction. Bonus fix surfaced by the golden gate: **generic fn
      headers** (`fn f<T: Display>(items: [T])`) previously degraded the
      whole header to raw tokens — now the `<…>` span becomes a raw
      GENERIC_PARAMS node and the param list parses structured (plus a
      collectSignatures guard: parens-but-no-PARAMS records *no*
      signature, never a wrong zero-arity one). Corpus unresolved heads
      40 → 25; golden library-face-fit checks fully.
- [ ] **B2 — struct values in HIR/MIR.** In progress:
      - [x] **B2a — SROA record bindings in `main`.** A record-literal
            `let`/`var` lowers to one scalar local per field *named with
            the dotted path* (`"p.x"`): since `p.x` parses as a single
            greedy PATH_EXPR, field reads, `var` field assignment
            (`q.x = q.x + p.x`), and `{p.x}` interpolation all resolve
            through the existing local machinery — no aggregate exists.
            i64/bool field values (consts, calls, other fields).
            Verified end-to-end in link-roundtrip.sh on wasm64 + wasm32.
            Honestly Unsupported (documented): shorthand inits,
            whole-struct copies/passing/returns, nesting, callee-body
            records, str fields.
      - [x] **B2b slice 1 — the layout story (escaping records).** Records
            that escape SROA are real memory now. Specced first:
            `spec/memory.md` §"Linear struct layout" (declaration order,
            natural alignment — bool 1/1, i64 8/8 — struct align = max
            field align, size rounded up, aligned allocation). Then the
            ladder: HIR `record_alloc`/`field_get`/`field_set`, MIR
            `record_make` (align `sp` → bump → store fields → yield base)
            + typed `field_get`/`field_set` loads/stores, backend emission
            with per-nesting-level base-ptr scratch locals (an inner
            record literal in a call argument can't clobber the outer's
            base). The builder lays out this file's structs
            (`registerStructs`), decides SROA-vs-materialize per `main`
            binding by a whole-value-use scan (`recordEscapes` — SROA
            stays for non-escaping literals), binds record-returning
            calls (`let p = make(3, 4)`), and registers record
            params/returns as one address-width `.ptr` (`fn_recs` tracks
            which struct; args are checked struct-for-struct —
            UnsupportedCall on mismatch). Field reads/assigns/`{p.x}`
            interpolation resolve via `findRecField` in `main` and in
            callee bodies. Verified end-to-end on wasm64 + wasm32
            (`link-roundtrip.sh` B2b: passed/returned/nested-call args,
            `var` field assign through the pointer, bool field layout →
            `3/25/5/31/c = (5, 4)/true/7`) + 8 unit tests incl. the
            honest rejections (wrong struct, missing/unknown field,
            field-assign on `let`, bool into i64 field).
            **Bonus fix:** `parseRecordBody` looped forever on a
            keyword-shaped field name (`on: bool` — `on` lexes KW_ON and
            `parseField` consumed nothing); a progress guard eats one
            token so the parse degrades instead of hanging (+ regression
            test).
            **Boundary (next slices):** nested structs (struct-typed
            fields), `str`/`ref` fields, record `let`s *inside* callee
            bodies, control flow in record-returning bodies (v0 = single
            tail expr), whole-record interpolation/printing, struct
            signatures across module boundaries (the table is per-file),
            `q64 show layout <type>`, and reclamation (the scope arena
            never frees). B4's `self` receiver can now build on this.
- [x] **B3 — face/fit method grammar.** `parseFaceOrFit` (raw header +
      raw balanced body) split into `parseFaceDecl`/`parseFitDecl`:
      face headers parse name + generic params + a structured super
      list (`: Eq + Display` → FACE_REF nodes); fit headers parse a
      structured FIT_SPEC distinguishing the two forms — `Type : Face`
      (colon) vs `Face<Args>` (bare) — which is exactly what B4's
      TYP201/TYP202 arity check reads. Bodies parse `fn` items as
      METHOD_SIG (name, generic params, structured params incl. the
      `self` receiver — KW_SELF is now a valid param name, `Param.
      isSelf()` — return type, optional Block; effects/`where` stay raw
      tokens); `type` aliases and `law`s stay bracket-tracked raw runs
      that can't swallow a following `fn` or the body's close (incl.
      one-line bodies). AST: `FaceDecl.methods()`, `FitDecl.spec()/
      methods()`, `FitSpec.isColonForm()/target()/face()`, `MethodSig`.
      Verified: 329/329 unit tests (4 new covering both fit forms,
      self/bodyless/default-impl sigs, super list + type/law runs),
      golden library-face-fit still checks clean, conformance 18/48
      unchanged, roundtrips + 78/78 CLI green.
- [x] **B4 — fit registration + static dispatch — DONE.** Definition of
      done met in full: `spec/tests/golden/library-face-fit.q` **compiles
      and runs** (prints its three colors, wasm64 + wasm32 — locked in
      link-roundtrip.sh), and the `wrong-fit-form-*.q` fixtures pass
      (TYP201/202). The closing slice was **B5's first rung,
      monomorphization**: a call to `fn f<T: Face>(items: [T])` stamps
      one private instance per inferred element type (`print_all<Color>`,
      deduped in `b.ids`); the `[T]` param lowers to a (ptr, count) pair
      (`Scope.arrs` with a *runtime* count — `Count` became
      konst-or-local); the stamped body builds entry-style (it may
      `env.out`) with its own locals list (`Builder.cur_locals`
      indirection); `T`'s methods resolve through the fit registry inside
      the body; the bound is checked at the call site (no fit →
      UnsupportedCall on the emit path; the TYP200 diagnostic wire in
      `q64 check` is a follow-up). Statement-position void calls landed
      as part of it (`print_all(...)` in `main`; lowerEntryStmt accepts
      void-returning call exprs). Generic declarations are skipped from
      the pub surface (they exist only monomorphized). Verified: golden
      runs both addrs + two-instantiation dedup (`show_all<A>` once,
      `show_all<B>` once → A1/A2/B9) + missing-fit rejection; 355/355
      unit (3 new), 79/79 CLI, conformance 20/48, roundtrips green.
      - [x] First slice: the fit registry + TYP201/TYP202 (see the A1
            fit-registry item) — the `wrong-fit-form-*.q` half of the
            definition of done.
      - [x] **Static dispatch lands.** `r.area()` — a dotted call whose
            head is a materialized record binding/param — resolves
            through the fit registry (now also built on the emit path,
            `Builder.fitreg`) to a **direct call**: the fit method
            registers as a plain HIR function named `Struct.method`
            with `self` as a B2b record param (`.ptr` base pointer);
            no vtable, no monomorphization. `self.w` field access and
            `self.other()` method-on-self composition work (`self`
            joined `isPathStart`/`isPathToken` so receiver paths parse
            and render like any other name); `-> bool` methods route
            `env.out` correctly via the type bridge; a method call
            counts as a whole-value escape so the receiver
            materializes. Honest rejections: unknown method →
            NameNotFound, wrong arity → UnsupportedCall, no-self /
            str-ret methods → Unsupported. Verified end-to-end on
            wasm64 + wasm32 (link-roundtrip B4 section: `42 / 420 /
            false / 9 / area = 42`) + 5 build_hir tests. 338 unit /
            79 CLI / conformance 20/48 / roundtrips all green.
      - [x] **str-returning fit methods** (the `Display.fmt` pattern):
            `fn fmt(self) -> str { "Rect({self.w}x{self.h})" }` — the
            body is a single tail str expr built like registerStrFunc;
            `{self.w}` interpolation rides the existing rec-field concat
            piece. `env.out(r.fmt())`, `let s = r.fmt()` (str binding),
            and dispatch on a record *param* in a plain callee
            (`describe(r) { r.area() }` — fell out of scope.recs, now
            regression-locked) all verified end-to-end wasm64 + wasm32
            (roundtrip: `Rect(6x7) / s = Rect(6x7) / 42`). isStrCall
            learned fit methods; HIR→MIR str calls take mixed arg kinds
            (the `.ptr` receiver lowers as a scalar operand).
      - [ ] Remaining for the golden program (`library-face-fit.q`
            compiles AND runs): u8 struct fields, `[T]` array literals
            + `for` iteration, format specs (`{self.r:02x}`), and
            generic `print_all<T: Display>` (face-bounded generics —
            the B5 ladder). Dispatch on receiver *expressions* landed
            (`make(1,2).area()`, `(Rect{…}).area()`), and fit-method
            calls inside interpolation landed too: `"{r.fmt()}"` is a
            str concat piece, `"{r.area()}"` formats decimal, and
            `{self.area()}` works inside another fit method's body.
            The escape scan reads string tokens for `{name.method(…)}`
            (interpolation is invisible to the CST walk), so the
            receiver materializes; plain `{name.field}` keeps SROA.
            **Spec reconciliation:** types.md normatively defers format
            specs (`{value:02x}`) to an open item, but faces.md's
            canonical example and golden/library-face-fit.q used
            `{self.r:02x}` — both now render decimal
            (`rgb({self.r}, …)`) with a pointer at the open item, so
            the golden target no longer depends on a deferred
            sublanguage.
- [x] **Arrays + `for` (the golden iteration shape).** Array literals
      materialize in the scope arena (`array_lit`/`array_make`: align,
      bump count·stride, fill slots — scalar elements store at width,
      record elements memory.copy inline so the element address IS the
      record value); a binding holds one `.ptr` local with a
      compile-time count (`Scope.arrs`). `for x in xs` desugars in the
      builder to an index loop (hidden `i`, per-iteration element
      assign — a record element binds `x` as a rec ptr so `x.fmt()`
      dispatches in the body); `xs[i]` is **bounds-checked and traps**
      per spec/types.md (one `bounds_check` op: evaluate-once index
      scratch, unsigned compare catches negatives, `unreachable`);
      `xs.len` folds to the count. Field/method access on *receiver
      expressions* landed alongside (`cs[0].r`, `colors[1].fmt()` —
      incl. str-returning methods via `recvStruct` routing). Verified
      end-to-end wasm64 + wasm32 (roundtrip arrays section incl. the
      oob-trap assertion) + 2 unit tests. **Boundary:** main-only
      (like all aggregate bindings); fixed-count literals (growth is
      Vec's job); `[T]` slice *params* land with B5 monomorphization
      (print_all); float/bool fields on receiver-expression access
      need sema-typed field exprs; narrow-field arithmetic through
      `cs[0].r + 1` widens silently (same gap) — closes when field
      exprs are sema-typed.
### Ladder C — enums + `match` lowering

- [ ] **C — enums + `match`.** The biggest blocked language surface
      (the conformance corpus and `errors.md` lean on `match`).
      Rungs: C1 unit variants + statement `match` (landed) → C2
      value `match` (landed) → C3 payload variants (landed) → C4
      literal patterns (landed) → exhaustiveness diagnostic (landed)
      → `Option`/`Result` in the prelude + generic enum declarations
      (landed) → enum returns from functions (landed) → `if let`
      narrowing (landed) → `T?` sugar (landed) → `try` (landed) →
      match in callee bodies + enum params (landed) → match in
      record-returning bodies (landed) → str enum payloads (landed)
      → Result-shaped `env.fs.read` (landed: `try env.fs.read(path)`
      propagates — the backend boxes Ok/Err directly, spec/env.md
      updated; ALSO fixed the latent pointer-bearing-return bug from
      the str-payloads rung: a `Result<str, _>`-returning call now
      SKIPS frame reclamation entirely — `ret_ptr_bearing` through
      hir/mir — since the flat slide would dangle the payload; the
      recursive slide lands with named regions) → `while let` (landed:
      the IF_COND_LET shape on `while`, desugared to a loop that
      re-evaluates the scrutinee, breaks on tag mismatch, binds
      payloads — roundtrip-locked wasm64+wasm32) → next:
      record enum payloads (landed: `Ok(Config)` / declared
      `Io(IoError)` slots — one cell holding the record's base
      pointer; match arms + `try` bind the record into `recs` so
      field access works; generic instantiation keys grew "r:Name"
      descriptors; rec payloads count as pointer-bearing returns.
      KNOWN ISSUE found: a user `fn start` collides with the MIR
      entry's internal name — rename pending) → the `fn start`
      collision (fixed: the entry's internal MIR name is now `#start`,
      a `#`-prefixed sentinel illegal as a q64 identifier — calls
      resolve by FuncId and the entry always exports `_start`, so the
      name is a backend handle only; `show mir` shows `fn #start`) →
      `let x = match …` in callees (landed: the bind-the-match form in
      a plain callee body desugars exactly like `main`'s C2 — a hidden
      mutable `#mres` local assigned per arm, then the named binding
      reads it; `buildIntMatchLet` shares `buildMatchInto`, whose
      unused `RtMap` param was dropped so it's main/callee-agnostic;
      enum + literal scrutinees both work, mixed-arm-type still
      rejected. Verified wasm64+wasm32: `classify`/`unwrap_or` →
      `101 201 1000 50 30`; 401 unit / 81 CLI / 24-of-51 / roundtrips
      green) → void-returning procedures (landed: a `fn` with no
      return type — a helper run for its side effects — now builds and
      runs. `registerVoidFunc` + `buildVoidStmt`/`buildVoidBlock`/
      `buildVoidIfNode`/`buildVoidEnvOut` build a body of `env.out(…)`,
      value `let`/`var` + reassignment, `if`/`else`, `while`, bare
      `return`, host-face calls, and statement-position void calls;
      `main` gained the same void-call statement. The body lowers
      through the existing entry/void path — `lowerEntryStmt` already
      handles every void inst — routed by `hf.ret == .void` in
      lower.zig. The callee param loop was factored into the shared
      `collectCalleeParams`. A void call in *value* position
      (`env.out(log(5))`) and a `return <value>` from a void proc are
      both rejected. Verified wasm64+wasm32: a `banner`/`count_down`/
      `describe` program and a void-calls-void program; 402 unit / 81
      CLI / 24-of-51 / roundtrips green. Boundary: no `match`, records,
      arrays, `for`, generics, or runtime str bindings in a void body
      yet — those are follow-ons) → statement-position callee matches
      (landed: a `match` with side-effecting void arm bodies inside a
      void procedure now works — `buildVoidMatch` reuses the
      `buildMainMatch` scrutinee/tag/exhaustiveness machinery but
      builds each arm through the void statement set, so arms run
      `env.out`, nested control flow, and void calls instead of
      yielding; block arms with multiple statements work. The void
      expr-statement logic was factored into `buildVoidExprStmt`,
      shared by `buildVoidStmt` and the single-`->`-expression arms.
      Enum (unit + payload), Option, and integer-literal scrutinees
      verified; non-exhaustive still rejected. wasm64+wasm32:
      `describe`/`report`/`grade` → `empty 48 rect 15 42 none zero one
      many`; 403 unit / 81 CLI / 24-of-51 / roundtrips green) → TYP305
      (`?` postfix) wired (landed: postfix `?` in expression position
      — the error sigil q64 deliberately omits in favour of the `try`
      keyword — now parses to a `QUESTION_EXPR` node and the check pass
      emits TYP305 pointing at the `?`; `?.` Option-chaining and the
      `T?` type sugar are untouched. Catalog entry + 2 unit cases +
      conformance `errors/question-on-result.q` flips → **25/51**) →
      `main` signature checks ENV050/ENV052 (landed: `checkMainSignature`
      in the check pass validates `main` against the four permitted
      shapes — `fn main`, `fn main -> Result<…>`, `fn main(env: Env)`,
      `fn main(env: Env) -> Result<…>` — emitting **ENV052** on a
      wrong-typed/extra param or a structured non-Result return, and
      **ENV050** when a Form-2 `main` falls off the end through a void
      op (e.g. `env.out`) with no `return`/Result tail; trailing
      `return`/`panic`/`if`/`match` and `Ok(())` tails stay silent,
      raw/unparsed returns are lenient. Catalog entries + 4 unit cases;
      conformance `env/main-signature-mismatch` + `env/main-form2-no-
      return` flip → **27/51**) → LEX021 (`&` in type position) wired
      (landed: `parseTypePrimary` flags a `&` opening a type — q64's
      reference syntax is `ref T`, not `&T` — with LEX021 and recovers
      by treating it as a `ref` type, so the rest of the signature
      parses and the source round-trips. A bitwise `&` in *expression*
      position is untouched. 2 unit cases; conformance
      `lexical/ampersand-in-type` flips → **28/51**) → TYP108 (generic
      default ordering) wired (landed: `checkGenericDefaults` scans a
      `GENERIC_PARAMS` token span, splits on top-level commas, detects a
      top-level `=` per param, and flags a non-defaulted param that
      follows a defaulted one — applied to fn/struct/enum via a new
      `StructDecl.genericParams()`. Nested `<>`/`[]`/`()` in a default
      value are depth-skipped; the TYP102 test, whose default is last,
      stays silent. 3 unit cases; conformance
      `generics/non-default-after-default` flips → **29/51**) →
      effect declarations + EFF140/EFF141 (landed: `effect @name` is
      now a parsed item — `KW_EFFECT` joined the item keywords,
      `parseEffectDecl` structures `pub? effect @IDENT` into an
      `EFFECT_DECL` (round-trips losslessly), and `ast.EffectDecl`
      exposes the marker name. The check pass emits **EFF141** when the
      name fails `^[a-z][a-z_]*$` and **EFF140** when a valid name
      collides with a core marker (the full blessed set from
      effects.md). Catalog entries + parser round-trip test + 5 check
      cases; conformance `effects/invalid-effect-name` +
      `effects/user-effect-shadows-core` flip → **31/51**) → LEX020
      (unknown typed-string prefix) wired (landed: the lexer already
      emits a `STR_PREFIX` token for `<ident>"…"`; the check pass now
      recursively scans the CST (`checkTypedPrefixes`) and emits
      **LEX020** for any prefix outside the auto-prelude set — v0 ships
      the one the prelude blesses, `url"…"` (reachable because `Url`
      shows up in `Net.get`'s signature, per modules.md / types.md).
      User-imported `StringLit` fits aren't resolved yet, so everything
      else flags. 1 check case (4 asserts incl. the `url"` non-fire and
      the per-prefix multi-flag); conformance
      `lexical/string-typed-prefix-unknown` flips → **32/51**; no
      regression on `streams/realtime-pipe-violation.q`'s `url"`
      usage) → effect annotations on functions + EFF120 wired (landed:
      `EffectSpec := EffectMarker ("+" EffectMarker)*` after a function's
      return type is no longer a raw token run — `parseFnDecl` parses a
      structured `EFFECT_SPEC` of `EFFECT_MARKER` (`@ IDENT`) nodes
      (round-trips losslessly; a `where` clause still collects raw), and
      `ast.FnDecl.effectSpec()` / `EffectSpec.markers()` / `EffectMarker.
      name()` expose the declared set. The check pass emits **EFF120**
      when an assert forbids a capability it's combined with —
      `checkEffectContradiction`: `@pure` forbids every capability,
      `@realtime` forbids all but the realtime-safe `@time`/`@random`/
      `@audio` carve-outs (effects.md §"`@realtime` and capabilities");
      the `@no_*` asserts bound *operations*, checked at the body level,
      not the declaration, so they don't contradict capability decls; two
      asserts compose and unknown user markers never contradict. Catalog
      entry + parser round-trip/structure test + 1 check case (11
      asserts); conformance `effects/contradictory-effects` flips →
      **33/51**; no regression on the `@realtime`-only / `@realtime +
      @stage` functions in golden/streams). The structured effect spec
      also unblocks EFF110 (assert/operation violations in the body) and
      ENV056) → EFF160 + ENV056 wired (landed: two more signature-level
      checks riding the structured effect spec. **EFF160** —
      `checkCancelCtx`: a `@cancel` function must take a `Cancel`-typed
      parameter (the cancellation token; matched on the param *type*, not
      the conventional name `ctx`), else error (effects.md §"`@cancel`
      and `@uncancellable`"). **ENV056** — `checkPureEnv`: a `@pure`
      function may not reference the ambient `env` (`referencesAmbientEnv`
      recursively finds a `PATH_EXPR` headed by `env` in the body); a
      parameter named `env` shadows the ambient binding and suppresses it.
      Found + fixed a real interaction: a `@pure` body using `env.out`
      now trips ENV056, so the EFF120 test's `@pure` cases were made
      env-free. Catalog entries + 2 check cases (8 asserts); conformance
      `effects/cancel-without-ctx` + `env/ambient-env-in-pure` flip →
      **35/51**) → REG050 wired (landed: the only cross-region move is
      `transfer(to: …)`; `copy_to`/`pin_to`/`intern` are reserved
      non-verbs the language omits (memory.md §"Cross-region transfers").
      `checkTransferVerbs` scans the CST for either call shape — a
      `METHOD_EXPR` (`make().copy_to(r)`) or the common
      `CALL_EXPR` over a greedy dotted `PATH_EXPR` (`a.copy_to(r)`, where
      the verb is the path's last dotted segment) — and flags the verb
      token. A bare (non-dotted) name isn't treated as a verb. Catalog
      entry + 1 check case (5 asserts); conformance
      `memory/unknown-transfer-verb` flips → **36/51**) → REG020 wired
      (landed: a `@managed` (WasmGC) struct may only hold managed or
      value-type fields; a `ref` into linear memory is rejected
      (memory.md §"Marking a struct `@managed`"). The `@managed`
      annotation passes through as sibling `@`/IDENT tokens (leading
      annotations aren't attached to the item node yet), so
      `checkManagedStructs` tracks it across the SOURCE_FILE child stream
      up to the next item node, then `flagLinearFields` flags each
      `ref`-typed field via the structured `Field.type_()`. Catalog entry
      + 1 check case (3 asserts); conformance `memory/linear-in-managed`
      flips → **37/51**) → STR051 wired (landed: `Event<T>` is pointwise
      and has no previous-tick value, so `.pre()` (the feedback one-tick
      delay, valid only on `Signal`) can't be called on an event
      (streams.md §"`pre()` for feedback cycles"). `checkEventPre`
      collects `Event<…>`-typed *parameters* (via the structured
      `Param.type_()` → `PathType.name()` head), then `scanEventPre`
      flags any `<event>.pre` `PATH_EXPR` in the body. `Signal.pre()` and
      non-`pre` methods stay silent. Catalog entry + STR subsystem
      mapping + 1 check case (3 asserts); conformance `streams/pre-on-event`
      flips → **38/51**; Event-typed `let` bindings are a follow-on) →
      ENV055 wired (landed: a `with_capabilities(use: { field: … })` key
      that isn't a field of `Env` (env.md §"Overriding the ambient
      binding"; the 14-field set: out/err/exit/args/envvars/time/random/
      net/fs/kv/audio/midi/ai/ui). The construct still parses raw, so
      `checkWithCapabilities` scans the flat token stream — after
      `with_capabilities (`, find the `use : {` map, then flag each
      top-level `IDENT :` key not on `Env` (depth tracking skips a value's
      own nested braces / `:` keys). Catalog entry + 1 check case (2
      asserts, incl. the nested-value non-fire); conformance
      `env/use-field-not-on-env` flips → **39/51**) → CONC020 wired
      (landed: `c.tell(Msg)` is fire-and-forget, but a reply-bearing
      handler (`handle Msg -> T`) needs `c.ask(Msg)` — concurrency.md
      §"`tell` vs `ask`". Same flat-token technique (the actor body parses
      raw): pass 1 collects reply-bearing message names — a `handle Name …
      -> …` with a top-level `->` before the body `{` (the message
      pattern's own `( … )` is depth-skipped); pass 2 flags each
      `tell(Name)` (KW_TELL) whose first arg is reply-bearing. `tell` on a
      non-reply handler and `ask` on a reply handler stay silent. Catalog
      entry + CONC subsystem mapping + 1 check case (2 asserts);
      conformance `concurrency/tell-on-reply-handler` flips → **40/51**) →
      CONC050 + CONC053 wired (landed: two more concurrency checks.
      **CONC050** — `channel<T>(…)` has no default policy, so a call with
      no top-level `policy:` argument is flagged (flat-token scan over the
      `channel … <…>? (…)` shape). **CONC053** — `for x in rx` over a
      cancel-aware receiver (`Receiver<_, Backpressure|LatestValue>`) with
      no `ctx`/`Cancel` parameter in scope; `checkCancelAwareFor` collects
      cancel-aware `Receiver<…>` params (via `PathType.genericArgsText`),
      treats a `ctx`/`Cancel` param as the token, and `scanCancelFor`
      flags a `FOR_STMT` whose iterable head is such a receiver. Catalog
      entries + 2 check cases (5 asserts); conformance
      `concurrency/channel-policy-required` +
      `concurrency/for-cancel-aware-without-ctx` flip → **42/51**) →
      STR060 wired (landed: a `@realtime` stage piped (`|>`) into a
      non-`@realtime` stage — streams.md §"Effects on stages".
      `checkRealtimePipe` builds the declared-fn + `@realtime`-fn name
      sets from the file's signatures (via the structured effect spec),
      then token-scans for each `PIPE_GT` (`|>`): `callNameBefore`
      back-matches the upstream call's `)` to its `(` to read the upstream
      stage name, the downstream name is the IDENT after `|>`, and it
      flags upstream-`@realtime` → downstream-declared-non-realtime. Fires
      exactly once on the test's `play |> http_post` (the `mic |> play`
      hop is non-realtime upstream, silent). Catalog entry + 1 check case
      (2 asserts); conformance `streams/realtime-pipe-violation` flips →
      **43/51**; the reverse "buffered stream → `@realtime`" shape needs
      stream-type info and is a follow-on) → TYP306 wired (landed: a
      `panic <payload>` whose type doesn't fit the `Panic` face —
      errors.md §"`panic` and `trap`". `checkPanicPayload` collects this
      file's `fit T : Panic` targets (via `FitSpec.target()`/`.face()`),
      then `scanPanicPayload` flags a **record-literal** panic payload
      (`NotAPanic { … }`) whose type is outside that set ∪ the blessed
      prelude payloads (`PanicMessage`/`Cancelled`/`Closed`/
      `RuntimeDenied`). String / bare-path / call payloads are left to the
      full payload-type check. Catalog entry + 1 check case (3 asserts);
      conformance `errors/panic-payload-not-panic-fitting` flips →
      **44/51**) → TYP207 wired (landed: a non-dyn-safe face used in `dyn`
      position — faces.md §"dyn-safety": every method must take `self`,
      not return `Self`, and carry no method type params.
      `checkDynSafety` builds the non-dyn-safe set — curated prelude
      `{Clone, Default}` (both return `Self`; the rest of the prelude
      predicate is spec-deferred) plus file-defined faces where
      `faceIsNonDynSafe` finds a static or `Self`-returning method — then
      token-scans `dyn <Face>` and flags a match. Catalog entry + 1 check
      case (3 asserts, incl. `dyn Display` staying silent and a
      file-defined `-> Self` face); conformance `faces/not-dyn-safe` flips
      → **45/51**) → STR020 wired (landed: a stage handed the wrong
      dataflow type — an `Event<T>` where a `Signal<T>` is expected, or
      vice-versa — streams.md §"Why three types instead of one".
      `checkDataflowTypes` builds a fn→decl map (for positional param
      types) and a stream-binding map from `let|var x: Signal|Event<…>`
      annotations (flat-token scan), then walks each `fn(arg0, arg1, …)`
      call, splitting args at depth-1 commas, and flags a bare-binding
      argument whose stream kind differs from the matching parameter's
      (`paramStreamKind`). Only stream↔stream mismatches fire, so the
      `graph-pipe-stages` golden (no annotated stream `let`s) stays clean.
      Catalog entry + 1 check case (2 asserts); conformance
      `streams/dataflow-type-mismatch` flips → **46/51**) → TYP102 wired
      (landed: a required generic argument that has no default and can't
      be inferred — spec/generics.md §"inference then default".
      `fnNeedsExplicitGeneric` parses a fn's GENERIC_PARAMS span (segments
      split on depth-0 commas, like checkGenericDefaults) for a
      non-`const`, non-defaulted type param whose name appears in **no**
      value-parameter type (`collectIdents` over the PARAMS subtree); such
      a param can only come from an explicit arg. `checkMissingGenericArg`
      then fires on the unambiguous shape — an unannotated `let x = f()`
      whose callee is such a fn and the call supplies no explicit generic
      args (EQ not COLON before the callee; `(` not `<` after it). Sound
      by construction: annotated lets / turbofish / inferrable params /
      other call positions are all skipped. Catalog entry + 1 check case
      (3 asserts); conformance `generics/missing-generic-arg` flips →
      **47/51**) → REG040 wired (landed: a `FreeList` region exited with
      live allocations — memory.md §"Region literal syntax". v0 heuristic
      — full drop-liveness is a spec-deferred item: `checkFreeListRegion`
      token-scans for `region <name>: FreeList { … }`, matches the block's
      braces, and flags it when the body has a `.new(` allocation but no
      `.free(`/`.drop(`. `Arena`/`Pool` regions (bulk-freed on exit) are
      untouched, so `unknown-transfer-verb`'s Arena blocks stay REG050-only.
      Catalog entry + 1 check case (3 asserts: leak / freed / Arena);
      conformance `memory/region-exit-live-allocs` flips → **48/51**) →
      TYP047 wired (landed: a `T?` used as a `T` without narrowing —
      types.md §"optional types and flow narrowing"; v0 narrowing is
      shallow/syntactic. The safe reads of an optional go through a
      *different* binding (`if let Some(x)` / `match`) or `?.`
      (a `QUESTION_DOT_EXPR`, distinct node), so a **direct** `param.field`
      on an optional parameter is the unsafe pattern. `checkOptionalNarrowing`:
      for each `.optional`-typed param, unless it's re-bound via a
      same-name `if let Some(<name>)` (conservative skip — no scope
      tracking in v0), `scanOptionalUse` flags a `PATH_EXPR` headed by the
      param with a `.`. Catalog entry + 1 check case (3 asserts: unnarrowed
      / non-optional / Some-reshadow); conformance
      `types/optional-not-narrowed` flips → **49/51**) → PAR040 wired
      (landed: a chained relational comparison `a < b > c` — the
      generic-args/less-than ambiguity (generics.md §"Why no turbofish").
      Key realization: the disambiguation needs to know whether the head
      is a *value* (→ less-than) or a *generic item* (→ generic-args), and
      the **check pass has scope info**, so PAR040 moved there from the
      parser (where it was deferred). In expression position `<`/`>` parse
      as binary ops (bp 4), so `a < b > c` is a left-assoc chained
      `BIN_EXPR`; `checkChainedComparison` collects the fn's value-binding
      names (params + `let`/`var`) and `scanChainedComparison` flags a
      `BIN_EXPR` (relational op) whose lhs is itself a relational
      `BIN_EXPR` and whose leftmost identifier is a local value. A
      type-headed `PCM<f32>(0.0)` (head not a local) and `&&`-separated
      comparisons (`a < b && c > d`, outer op not relational) are left
      alone; `Box<i64, heap>` stops at the comma (single op). Catalog
      entry already present; 1 check case (4 asserts); conformance
      `parser/generic-vs-less-than` flips → **50/51**) → NAM002 wired
      (landed: a quoted-relative import that escapes the qube — modules.md
      §"Resolution algorithm". Needs the filesystem, so it lives in
      `cmdCheck` (main.zig), not the pure sema pass: `findQubeRoot` walks
      up from the file's directory to the nearest `qube.json5` (the qube
      root); `importEscapesQube` resolves+normalizes the import against the
      importing file's directory and flags it when it lands outside the
      root. When no manifest is found (a loose file checked standalone, as
      in the conformance corpus) the file's own directory is the boundary,
      so `../../../other-qube/...` is flagged while a real qube's in-tree
      `../shared/util.q` resolves correctly under its manifest root. Uses
      `ast.ImportStmt.isRelative()/.path()` + a new `.offset()`. Conformance
      `modules/import-path-escapes-qube` flips → **51/51 — FULL CONFORMANCE**;
      unit / 81 CLI / round-trips all green.)

**Conformance corpus complete: 51 of 51.** The diagnostic ladder (begun
from the 31/51 floor) is finished — every spec/tests case passes, message
text aside. Net-new diagnostics this arc: LEX020, EFF120/EFF140/EFF141,
EFF160, ENV055/ENV056, REG020/REG040/REG050, STR020/STR051/STR060,
CONC020/CONC050/CONC053, TYP047/TYP102/TYP207/TYP306, PAR040, NAM002, plus
structured fn effect-spec parsing. Next frontiers are no longer the
negative-diagnostic corpus: positive codegen surface (the IR/codegen
ladder) and the deferred parser items (structured `graph`/`scope`/`actor`
bodies, leading annotations).
      - [x] **str enum payloads + generic-enum instantiation.**
            `Result<str, i64>`, `Option<str>`, and declared str slots
            (`Msg.Text(str)`) work end-to-end: construction
            (`Ok("found it")` — a str arg to a generic slot picks the
            str instantiation; `Err(404)` rides the layout-compatible
            base, relaxed by `enumCompatible`), match arms binding str
            payloads (`Ok(content)` → two .ptr locals read from cells
            8/16 via `num_cast .ptr`), and **`try` with a str Ok
            payload** (`let s = try lookup(n)` binds a str). The
            pieces: `EnumVariant` gains `kind` (ints / str_ / param) +
            `pidx`; `instantiateEnum` caches per-key (`"Name\0siii"`)
            clones with resolved kinds and a re-sized box —
            annotations (`-> Result<str, i64>`, `str?`) and
            construction inference share the cache so type identity
            stays pointer identity; `record_alloc`/`record_make` grew
            a `str_inits` channel (the pair stored widened into two
            8-byte cells); str body bindings declare via
            `declareStrBodyLocal` (scope `.str` entry backed by two
            address-width locals — the callee locals collectors map
            `.str` → `.ptr`). Verified end-to-end wasm64 + wasm32
            (roundtrip str-payloads section) + 1 unit test. 400 unit /
            81 CLI / 24-of-51 / roundtrips green. **Boundary:**
            single-slot str/param payloads (multi-slot stays the i64
            floor); record payloads later; `env.out` of a whole enum
            still unsupported.
      - [x] **Match in record-returning bodies.** Transform functions
            close the loop: `fn flip(o: Option<i64>) -> Option<i64> {
            match o { Some(v) -> Some(v * 2), None -> Some(0) } }` and
            Option→Result conversion both work. `buildRecTailStmt`
            gained a `match` arm (`buildRecMatch`): same value-if-chain
            shape as `buildIntMatch`, with each arm built as a record
            value of the declared enum (`recValueStmt` — a
            wrong-enum arm rejects `unsupported_call`); exhaustive-
            without-`_` promotes the last arm to the chain's else.
            No lowering changes — the `.block` tail recursion from the
            callee-match rung covers it. Verified end-to-end wasm64 +
            wasm32 (roundtrip record-match section: `42 / flipped none
            to 0 / err 7`) + 1 unit test (both transforms; wrong-enum
            arm rejection). 395 unit / 81 CLI / 24-of-51 / roundtrips
            green.
      - [x] **Match in callee bodies + matchable enum params.**
            `fn area(s: Shape) -> i64 { match s { Empty -> 0, … } }`
            and `fn unwrap_or(o: Option<i64>, d: i64) -> i64` work —
            the value-match form in plain callees: `buildIntMatch`
            lowers a callee `match` to a value `if` chain (hidden
            scrutinee set + chain in one block; the lowering reads a
            `.block` tail as a nested value block — new tail arm in
            `lowerIntBlock`). An *exhaustive* match without `_` makes
            the last arm's test redundant — it becomes the chain's
            else, so every path yields. The bookkeeping split that
            made match main-only is resolved by `declareBodyLocal`
            (entry-style bodies mirror locals into `b.cur_locals`,
            callee scopes — new `Scope.callee` flag — track via
            `declare` alone); `declareMatchScrutinee` and the payload
            binds in `resolveArmPattern` go through it. `enumOfExpr`
            resolves an enum-typed param/record binding via
            `scope.recs` (si.name → registry, identity-checked).
            Verified end-to-end wasm64 + wasm32 (roundtrip
            callee-match section: `48 / 15 / 0 / 7 / 99`) + 1 unit
            test (Shape/Option params; non-exhaustive and
            mixed-arm-type rejections). 394 unit / 81 CLI / 24-of-51 /
            roundtrips green. **Boundary:** value arms only (`->`
            expression of one scalar family; block arms and
            side-effecting statement-position matches in callees are
            later); no match in *record-returning* callee bodies yet
            (the tail there is expr/if only); `let x = match …` inside
            a callee (bind-the-match form) still unsupported — write
            it as the tail or restructure. (SUPERSEDED: the bind form
            landed later — see the `let x = match …` rung above.)
      - [x] **`try` propagation + TYP300 (v0 floor).** `let x = try
            half(n)` inside a Result-returning fn desugars to: bind
            the operand's boxed value once, `if tag == Err { return
            <the value> }` (same-E only — the From-conversion rung is
            later, and at this floor the boxed representation is
            identical either way), then bind the Ok payload slot
            (`buildTryLet`). The enabler: record/enum-returning bodies
            now take **leading statements** (`buildRecBody` walks all
            statements — the shared callee-body set via `buildIntStmt`,
            the try-let intercepted — and collects the declared locals;
            previously single-tail-only). `q64 check` emits **TYP300**
            (`try` where the enclosing return provably isn't `Result`:
            void, builtins, prelude types, `T?`, structural types,
            local structs/enums; an unknown named return — possibly an
            alias — stays silent), catalog entry included. Conformance
            `errors/try-without-result-return.q` flips → **24/51**;
            roundtrip try section (`ok 3 / err 3 / err 7` — the middle
            case propagates the *second* try's Err) wasm64 + wasm32;
            393 unit / 81 CLI green. **Boundary:** `try` only as a
            `let` initializer in a callee (no nested `Ok(try …)`, no
            statement-position try, none in `main` — main isn't
            Result-returning); E-type equality unchecked (generic args
            are raw text; same boxed shape regardless); TYP305 (`?` on
            Result) still unwired. (TYP305 NOW WIRED — see the rung below.)
      - [x] **`T?` sugar.** `-> i64?` ≡ `-> Option<i64>` (errors.md):
            the optional TypeExpr (already parsed structured) maps to
            Option's boxed shape in `structOfType`/`enumOfRet` (emit)
            and `enumAnnotation`/`enumOfNamed` (check — annotations and
            signature returns, so TYP062 judges `T?` seams too).
            Verified end-to-end wasm64 + wasm32 (roundtrip T?-sugar
            section: `42 / none`) + 1 unit test + check cases. 391
            unit / 81 CLI / 23-of-51 / roundtrips green. **Boundary:**
            `T?` params (like enum params generally) and `?.` chaining
            are later.
      - [x] **`if let Some(v)` narrowing in `main`.** The binding `if`
            desugars to a one-arm match: the parser already produced
            `IF_COND_LET` (pattern + scrutinee), now surfaced as
            `ast.IfStmt.ifLet()` / `ast.IfCondLet`; `buildMainIfLet`
            evaluates the scrutinee once (`declareMatchScrutinee`),
            resolves the pattern through `resolveArmPattern` (payload
            bindings in scope for the then-block via `prependPrelude`),
            and folds `if tag == want { binds; then } else { else }`
            (`foldMatchChain`, one arm + the else as default). `else`
            blocks and `else if (let)` chains compose (the chain just
            recurses through `buildMainIfNode`). The desugar wraps in a
            statement-position block (hidden scrutinee set + tag test),
            which `lowerEntryStmt` now lowers (`.block` arm — the
            switch became exhaustive, else prong dropped). Verified
            end-to-end wasm64 + wasm32 (roundtrip if-let section: `42 /
            nothing / err 9 / none indeed`) + 1 unit test (payload
            bind, else, else-if-let chain; non-enum scrutinee
            rejection). 390 unit / 81 CLI / 23-of-51 / roundtrips
            green. **Boundary:** `main`-only (callee bodies wait on
            match-in-callees); enum patterns only (no literal/tuple
            heads); no `while let`; a wildcard head is Unsupported
            (always-taken `if let _` is pointless).
      - [x] **Enum returns from functions (the cross-fn enum story).**
            `fn find(n: i64) -> Option<i64> { if n > 0 { Some(n) } else
            { None } }` works: `structOfType` resolves a boxed enum
            name to its arena shape (generic args allowed — they only
            parameterize the uniformly-8-byte payload slots), so enum
            returns ride the B2b record machinery (`.ptr` base
            pointer); record/enum-returning bodies grew their first
            control flow — the tail may now be an `if`/`else-if`/`else`
            *value chain* (`buildRecBody`/`buildRecTailStmt`; every
            path must yield the declared enum, missing `else` and
            wrong-enum tails reject `unsupported_call`; the existing
            `lowerValueIf` lowers it, type-threaded as `.ptr`). Callers
            bind and match: `enumOfExpr`'s call arm reads the callee's
            return type (`enumOfRet`), so `let o = find(5); match o`
            and `match find(-3)` both resolve arms. `q64 check`
            follows across the seam: an enum-returning call types as
            an enum value (`enumOfNamed` on the signature's lowered
            return), and an enum-*annotated* `let` (`let s: Shape =
            mystery()`) binds judgeably (`enumAnnotation`, judged
            against the enums table since the null-table lowering
            leaves local names unresolved) — TYP062 now fires across
            calls and annotations. Verified end-to-end wasm64 + wasm32
            (roundtrip enum-returns section: `found 5 / none for
            negatives / code = 40 / 14`) + 3 unit tests (Option/
            Result/local-enum returns incl. else-if chains; missing-
            else and wrong-enum rejections; check TYP062 across call +
            annotation). 389 unit / 81 CLI / 23-of-51 / roundtrips
            green. **Boundary:** leading statements in enum/record
            bodies (only the tail statement today); enum *params* pass
            struct-checked but can't be `match`ed inside a plain
            callee (match in callee bodies is its own rung); immediate
            (all-unit) enum returns (an i64 tag, not a record);
            `env.out` of an enum value.
      - [x] **`Option`/`Result` in the prelude + generic enums (v0
            floor).** Generic enum *declarations* register now — no
            monomorphization needed at this floor: every payload slot
            is uniformly 8 bytes (C3's boxed shape), so `enum BoxE<T>
            { Full(T), Empty }` lays out identically for any scalar T
            (a `T` slot rides the i64 compute floor; `registerEnums`
            reads the `<…>` header via `parseGenericSig`, new
            `ast.EnumDecl.genericParams()`). On top of that,
            `Option<T>`/`Result<T, E>` register as auto-prelude enums
            (spec/errors.md §"Result and Option") with **bare
            constructors**: `Some(40)`, `None`, `Ok(7)`, `Err(3)`
            construct without qualification (`enumVariantTag` resolves
            a dotless name through `sema.prelude.ctorEnum` → the
            registry, so a file `enum Option` **shadows** the prelude
            — and drops the bare form for variants it lacks, honestly
            NameNotFound). `None` was the landmine: it lexes as
            `KW_NONE`, which (a) hung the parser forever on any enum
            declaring a `None` variant — `parseVariant` only took
            IDENT and the variant loop had no progress guard (the same
            bug class as B2b's `on:` field fix; guard + KW_NONE-as-name
            landed, pre-existing bug) — and (b) parses as a *literal*
            expression, not a path, so `let e = None`, match scrutinees,
            and `enumOfExpr` gained literal arms routing KW_NONE to the
            (possibly shadowed) Option unit alloc; match arms already
            parsed `None` as ENUM_VARIANT_PATTERN and `patternHeadName`
            learned the KW_NONE head. `q64 check` follows: TYP062 knows
            the prelude pair (`collectEnums` adds them shadow-aware),
            bare ctor calls/paths and the `None` literal type as enum
            values. specs: modules.md prelude row lists the ctors.
            Verified end-to-end wasm64 + wasm32 (roundtrip prelude-enum
            section: `42 / none / ok 7 / code = 300 / 27`) + 6 unit
            tests (constructors/match/None-literal, generic enum,
            non-exhaustive rejection, shadowing, parser hang
            regression, check TYP062 incl. shadow-silence). New
            conformance fixture `types/non-exhaustive-option-match.q`
            flips **23/51**; 386 unit / 81 CLI / roundtrips green.
            **Boundary:** payload slots stay the i64 floor (str/record
            payloads later); `T?` sugar, `?.` chaining, `try`, and
            Option/Result *returns* from functions (cross-fn enum
            signatures) are later rungs; `env.out(o)` of an enum value
            still prints nothing useful (variant-name formatter is a
            nicety rung).
      - [x] **TYP062 emitted in `q64 check` — non-exhaustive match.**
            Specced first (types.md gains the row; `Result`-specific
            guidance stays TYP302). The check pass collects this
            file's enums (name → variants), types enum values
            (`Light.Yellow`, constructions, bindings —
            `Info.enum_value`), and judges both match forms (the
            statement walk + a `.match` expr arm): covered-variant
            bitmask, `_` short-circuits, unjudgeable shapes (unknown
            scrutinee, non-variant heads, literal patterns) stay
            silent. New fixture `types/non-exhaustive-match.q` flips
            conformance **22/50**; 379 unit (2 new) / 80 CLI /
            roundtrips green. (The emit path's structural rejection
            stays — the diagnostic is the friendly wire.)
      - [x] **C4 — integer literal patterns.** A non-enum scrutinee
            that is provably an i64 matches integer-literal arms
            (`match n { 0 -> .., 1 -> .., _ -> .. }`), statement and
            value forms, riding the same chain (LoweredArm.tag holds
            the literal). A `_` arm is required (ints aren't
            enumerable — the coverage bitmask only applies to enums,
            and is gated so large literals can't overflow it).
            str/float literals, binders, and ranges on scalars are
            later. Verified wasm64 + wasm32 (roundtrip C4 section:
            one / 200) + 1 unit test (incl. the missing-`_`
            rejection). 377 unit / 80 CLI / 21-of-49 green.
      - [x] **C3 — payload variants.** Boxed enums land, specced
            first (`spec/memory.md` §"Enum representation (v0)"): an
            enum with any tuple payload is an arena record
            `{tag at 0, p_i at 8·(i+1)}`, size 8·(1+max arity), align
            8 — every value incl. unit variants shares the shape, so
            the whole record machinery is reused (a synthetic
            `StructInfo` per boxed enum; `record_alloc` builds the
            value). `Shape.Circle(7)` constructs (arity-checked,
            `buildRecExpr`-interception like generic record calls);
            `Shape.Empty` of a boxed enum allocates `{tag}` (and is
            gated OUT of the immediate-tag path); `match` reads the
            tag from slot 0 (`foldMatchChain` boxed flag) and payload
            patterns `Circle(r)` / `Rect(w, _)` bind fresh i64 locals
            loaded from the slots — pattern resolved before the arm
            body so bindings are in scope, in statement AND value
            matches. Exhaustiveness tightened to a per-variant seen
            bitmask (duplicate arms no longer fake coverage — a C1
            hole). Floor: tuple payloads of ≤4 `i64` slots; record
            payloads, other field types, nested patterns, literal
            patterns are later. Verified end-to-end wasm64 + wasm32
            (roundtrip C3 section: 14 / area = 12 / empty / 9) + 2
            unit tests (construction/bindings/value-match/boxed-unit;
            arity + bare-payload-pattern rejections). 376 unit / 80
            CLI / 21-of-49 / roundtrips green.
      - [x] **C2 — value `match` (let initializers + assignment RHS,
            scalar yields).** `match` parses in expression position
            now (`MATCH_EXPR` primary sharing `parseMatch` with the
            statement form — grammar.md already said match yields a
            value; `ast.Expr.match` view). The builder desugars: a
            `let x = match l { … }` declares a hidden result local,
            lowers the match with each arm assigning it (the same
            scrutinee/tag/exhaustiveness machinery as C1, shared via
            `foldMatchChain`/`LoweredArm`), then binds the name
            reading the result — so an initializer can't see itself.
            `x = match …` assigns the target directly (plain `=`
            only, type-checked). The yield type is the first arm's
            scalar (`matchValueTy`); every arm checks against it —
            i64/f64/bool/f32, no mixing; str/record arms and other
            expression positions (`env.out(match …)`, call args) are
            later. Verified end-to-end wasm64 + wasm32 (roundtrip C2
            section: `wait 5s` / `1.5` / `103`) + 2 unit tests
            (let/assign + f64 yield; mixed-type and non-exhaustive
            rejections). 374 unit / 80 CLI / 21-of-49 / roundtrips
            green.
      - [x] **C1 — all-unit enums + statement `match` in `main` (and
            stamped generic bodies — they share the builder).**
            A variant value is its **declaration-order tag** (an i64
            at the compute floor; storage width + payload layout are
            later rungs' spec work). `registerEnums` registers
            all-unit enums (payload variants skip the enum — a use is
            honestly Unsupported); `Enum.Variant` resolves in the
            path arm to its tag const; an enum-valued `let`/`var`
            registers in `Scope.enum_binds` so `match` knows the
            scrutinee's enum. `buildMainMatch` evaluates the
            scrutinee once into a hidden local and folds arms
            back-to-front into an if/else chain on tag equality —
            bare variant names resolve against the scrutinee's enum
            (unknown name → NameNotFound), `_` is the default, and
            the v0 floor requires structural exhaustiveness (every
            variant or a `_`; else Unsupported — the diagnostic wire
            is the `q64 check` rung). Arm bodies are blocks or `->`
            expression statements (the expr-statement builder was
            factored into `buildMainExprStmt`, shared). Verified
            end-to-end wasm64 + wasm32 (roundtrip C1 section: slow /
            moving+fast / direct red) + 3 unit tests (tags + chain;
            non-exhaustive rejection; non-variant arm name). 372
            unit / 80 CLI / 21-of-49 / roundtrips green.
            **Boundary:** `match` as a value expression, payload
            variants, literal patterns, enum printing (`env.out`
            of an enum prints its tag today — the variant-name
            formatter is a later nicety), and cross-module enums.

- [ ] **B5 — generics beyond the first rung.** Monomorphization's v0
      floor landed with B4's close (one `<T: Face>` param, `[T]` slice
      params, record element types, void returns, statement calls).
      Remaining: const generics; then `dyn` dispatch (separate ladder).
      - [x] **Record `-> T` returns.** The `-> T` story closes: a
            generic whose T infers to a record returns its base pointer
            (`first<Color> -> ptr`), with the instance registered in
            `fn_recs` (ret + per-param struct info) so callers know.
            The pieces: `genericRecCall` intercepts `buildRecExpr`'s
            call arm (cheap `-> T` pre-check, then infer/stamp and read
            `fn_recs.ret`); the stamp's value tail builds via
            `buildRecExpr` when the return is a record (struct-checked);
            `main`'s let arm gates record-call bindings on a
            `buildRecExpr` probe for `.call` initializers instead of
            the name-based `recCallStruct` (a bare `let q = p` stays
            the documented copy-rejection, not a silent alias). So
            `let c = first([Color{…}, …]); c.fmt(); let d = idr(c)`
            binds, dispatches, reads fields, and chains. Printing a
            whole record value stays unsupported. Verified end-to-end
            wasm64 + wasm32 (roundtrip bare-T section extended:
            `rgb(9, 8)` / `8`) + 2 unit tests. 368 unit / 80 CLI /
            21-of-49 / roundtrips green.
      - [x] **Method dispatch on generic call expressions.**
            `first([Color{…}]).fmt()` / `.area()` and
            `idr(Color{…}).r` work without binding first:
            `genericRetStruct` is the non-building twin of
            `genericRecCall` — `recvStruct`'s call arm peeks a generic
            callee's `-> T` slot from the deciding argument (record
            literal → `b.structs`; bindings/index/calls recurse through
            `recvStruct`; slice args read `Scope.arrs` or the literal's
            first element) so the str/int routing predicates
            (`isStrCall` → fit-method return type) classify correctly;
            the *building* method arms already went through the
            generic-aware `buildRecExpr`. **Boundary (pre-existing, not
            generic-specific):** a call-receiver method inside
            interpolation (`"{first(cs).fmt()}"` — and equally
            `"{make(1,2).fmt()}"`) isn't a recognized interpolation
            piece shape; bind first. Verified end-to-end wasm64 +
            wasm32 (roundtrip: `rgb(4, 5)` / `6`) + 1 unit test.
            369 unit / 80 CLI / 21-of-49 / roundtrips green.
      - [x] **Bare `T` params + scalar `-> T` returns.** The feared
            "receiver-by-value story" mostly dissolved: a record T
            already crosses calls as its base pointer (B2b), so
            `fn show<T: Display>(x: T)` takes a record literal or
            binding (`x.fmt()` dispatches — the param registers in
            `recs`), and a scalar T is a plain scalar param. `-> T`
            returns the slot's scalar — `twice(21)` is i64,
            `twice(1.5)` is f64, `first([10, 20])` reads `[T]` element
            type — typed correctly at the *caller* too: `Env.callRet`
            now carries the CallExpr, so the build_hir bridge infers a
            generic `-> T` call's scalar from the deciding argument
            (`genericRet`; bare arg's type or slice arg's element).
            `fits.bareWhich`/`typeWhich` join `sliceOfWhich`; slice/
            bare/concrete params mix on one slot (`nth_plus`). TYP200
            judges bare record args like record arrays. Honest
            boundaries: record `-> T` rejects (needs caller fn_recs
            plumbing), scalar-to-bounded-bare rejects (no scalar
            fits). Verified end-to-end wasm64 + wasm32 (link-roundtrip
            bare-T section) + 4 unit tests. 367 unit / 80 CLI /
            21-of-49 / roundtrips green.
      - [x] **Multiple type params.** `fn both<T: D, U: D>(xs: [T],
            ys: [U])` works: `sema.fits.GenericSig` is a bounded list
            (`max_generic_params` = 4; `parseGenericSig` scans
            `< T (: F)? (, …)* >`), `sliceOfWhich` maps a fn param to
            its slot, inference fills one `TSlot` (ElemKind + stride)
            per slot independently (every slot needs a `[T]` inference
            source), bounds check per slot, and the stamp key joins all
            slot names — so `both<A, B>` and `both<B, A>` are distinct
            instances and `zipped_count<i64, f64>` mixes scalar slots
            in a value-returning generic. sema's TYP200 resolves the
            bound per slice param too (the multi-param fixture shape
            judges each slot). Verified end-to-end wasm64 + wasm32
            (link-roundtrip multi-param section) + 3 unit tests (both
            orders + mixed-scalar value; non-fitting second slot;
            TYP200 per-slot). 364 unit / 80 CLI / 21-of-49 /
            roundtrips green.
      - [x] **Value-returning generic calls.** A `-> i64`/`bool`/`f64`/
            `f32` generic stamps a *value* instance: `count_of(xs)`,
            `let n = total(xs)`, `count_of(xs) + 100`, and a bounded
            `total_area<T: HasArea>` summing `r.area()` over the slice
            all work. The pieces: `buildGenericCallStmt` split into a
            shared `buildGenericCall` (inference/bound/stamp walk → call
            expr) + the void statement wrapper; `buildIntExpr`'s call
            arm intercepts generic callees before `registerFunc`;
            `stampGeneric` reads the declared return scalar and builds
            the body's last statement as the value tail (tail expr or
            `return expr` — entry-style statements before it, so
            for-loops and `env.out` still work); `lower` gives a
            value-returning screen func `lowerIntBlock(body, ret)`
            instead of the void entry lowering (the setup-statement set
            is shared, so nothing else changed). `-> T` rejects
            honestly (needs by-value T). Verified end-to-end wasm64 +
            wasm32 (link-roundtrip value-generics section: 26 /
            total = 60 / 102) + 2 unit tests (value stamps incl. f64
            elements; `-> T` rejection). 361 unit / 80 CLI / 21-of-49 /
            roundtrips green.
      - [x] **Scalar element types.** An *unbounded* generic stamps per
            scalar element type too: `each([10, 20])` → `each<i64>`,
            `each([1.5])` → `each<f64>` (deduped per T like records;
            literal and binding arguments). The gate was one rejection:
            inference now carries `ElemKind` (record or scalar) instead
            of a StructInfo, `stampGeneric` takes elem+stride and keys
            the instance by `@tagName` for scalars, and the stamped
            body reuses the existing scalar-array machinery (`for`
            loads at width, `{x}` formats by local type). A *bounded*
            generic still takes record elements only — scalars have no
            fits yet, so `show_all<T: D>([1, 2])` rejects honestly.
            Verified end-to-end wasm64 + wasm32 (link-roundtrip B5
            section) + 2 unit tests (per-type stamp + dedup; the
            scalar-vs-bound rejection). 359 unit / 80 CLI / 21-of-49 /
            roundtrips green.
      - [x] **TYP200 emitted in `q64 check`** (B4's diagnostic
            follow-up). The check pass owns the generic bound check:
            `GenericSig` parsing + `[T]`-param detection moved to
            `sema/fits.zig` (shared with the emit path's
            monomorphization — ir already imports sema), the checker
            types record literals (`Info.record`, via the symbol table
            that checkFile already received) and arrays-of-records
            (`Info.rec_array`, all elements one local struct), and a
            call argument bound to a face-bounded generic's `[T]`
            param with no (target, face) fit in the registry emits
            **TYP200** at the argument. Honesty rules: fires only when
            the face is judgeable locally (declared or auto-prelude)
            and the element type is a provable local-struct record
            array; unbounded generics, unknown faces, unknown/mixed
            elements stay silent. The fit registry now feeds `checkFile`
            (built once in `cmdCheck`, also kept for TYP201/202). New
            conformance fixture `faces/no-fit-for-bound.q` flips
            (**21/49**, zero regressions); 357 unit (2 new) / 80 CLI
            (1 new TYP200 envelope case) / link-roundtrip green.

## Memory reclamation — Stack discipline on the implicit arena

The arena-never-frees era is over. Specced first
(`spec/memory.md` §"Frame reclamation (v0)"), then landed as a
**caller-side calling convention** — correctness never depends on an
analysis.

- [x] **Watermark + slide + host-statement reset.** Every call site
      saves `sp` before its arguments evaluate and reclaims after: a
      scalar result restores `sp` outright; an aggregate result (str
      bytes, record, boxed enum) is **slid down** onto the watermark
      (`memory.copy` is memmove — the overlapping downward copy is
      safe; record slides 8-align the watermark; the size rides
      `hir.Func.ret_size` → `mir.Func.ret_size`, set from `fn_recs`)
      and `sp` advances past exactly the result. Host statements
      (`env.out`, `qview.*`) reset to their own watermark — the host
      consumed the bytes. Backend: a per-region-nesting-level scratch
      group [wm + one stash per value type] (`Scratch.region_depth`,
      `Lowerer.region_base/region_lvl`, `slideCall`/`resetAfter`);
      nested calls in arguments wrap one level deeper, host wraps and
      call wraps share the level counter so saves can't clobber.
      `mergeScratch` now also folds `rec_depth` (a pre-existing
      drop for records nested in scanned subtrees). Verified: the
      roundtrip reclamation section — a 9000-iteration formatted-print
      loop (18001 lines) that **trapped out-of-bounds before** now
      runs in constant memory, wasm64 + wasm32 — plus the entire
      existing corpus (unit / roundtrip / conformance / CLI /
      component-roundtrip) byte-identical green.
      **Pinned boundary (specced):** the flat slide is a deep copy
      only while aggregates are pointer-free (true at this floor);
      a pointer-bearing field's return must slide recursively or
      caller-allocate — decided with the feature that introduces it.
- [ ] **Known leaks (recorded in the spec):** a loop-iteration
      rebinding abandons its prior bytes; concat temporaries feeding a
      `let` (not a host statement) in `main`. Next rungs:
      per-iteration reset via the existing escape scan; explicit
      `scope { }` reset (parser: scope blocks are still unstructured).
- [x] **Growth for collections — the `Vec` v0 floor landed.**
      Specced first (types.md §Growable, "v0 floor"): `Vec.from([…])`,
      `v.push(x)`, `v.len` (live), bounds-checked `v[i]` (trap), and
      `for x in v` (the loop bound reads the live len, so a pushing
      body still terminates). Representation: a 3-slot {data, len,
      cap} header at address width; i64 elements; copy-on-grow ×2
      (min 4). The runtime lives in three backend helpers
      (`__vec_new`/`__vec_push`/`__vec_get` + `__vec_len`) — direct
      Binaryen calls, NOT MIR calls, so the frame-reclamation slide
      never reclaims a grown block out from under a live vec. IR:
      `vec_new/vec_push/vec_len/vec_get` through HIR/MIR/print/
      effects; builder: `Scope.vecs`, the `Vec.from` let arm,
      statement `v.push`, path/index/for arms. **Parser fix:** `from`
      lexes KW_FROM (reserved, used by no production) — it now joins
      path segments (parse + ast `isPathToken`) so `Vec.from` parses
      as one dotted path. Verified end-to-end wasm64 + wasm32
      (roundtrip Vec section incl. 200 pushes through several growth
      cycles: `3 / 10 / 30 / 5 / 50 / sum = 150 / 205 / 199`) + 1
      unit test (ops + the vec-across-fn-boundary rejection). 398
      unit / 81 CLI / 24-of-51 / roundtrips green. **Boundary:**
      i64 elements; main-only (a vec param/return is honestly
      rejected — callee growth would allocate into a dying frame;
      the escape story lands with named regions); `Vec<T>.new()`
      waits on generic-args expressions; pop/insert/remove and
      record elements are later slices.

## Strings beyond the floor — methods landed

- [x] **The str method floor, wired end-to-end.** `s.len`, `s[i]`
      (unsigned byte), `s.slice(a, b)`, `s.contains(x)`,
      `s.starts_with(x)`, `s.index_of(byte)` work on runtime str
      values in `main` and in callees — plus **mixed signatures**
      (`fn has(s: str, sub: str) -> bool`, str + scalar params in
      value functions) and str arguments at call sites. The MIR ops +
      builder arms existed (dead code — unreachable for lack of
      typing/routing/signatures); this rung wired them: sema
      `scalarOf` gained `.index`/`.method` arms + a `strMethodType`
      table; the build_hir bridge types the dotted forms (`s.len`,
      `s.contains` as a dotted callee); main's `env.out` and `let`
      route `.str`-typed expressions through `buildStrExpr`; main's
      runtime str bindings register in the scope (two slots, ptr at
      idx / len at idx+1) so the method arms resolve them; and
      `registerFunc` accepts str params (one hir param, two scope
      slots, `buildCallArgs` gained the `.str_` kind). **Convention
      unification:** `registerStrFunc` now also declares two slots
      per param and `buildConcat`'s param piece builds a raw
      `str_binding` — retiring the one-slot/`str_param idx*2` dual
      convention, which **fixes a latent bug** (a passthrough of the
      *second* str param read wasm slots 1,2 instead of 2,3 —
      regression-locked). Verified end-to-end wasm64 + wasm32
      (roundtrip str-methods section: `11 / 104 / hello / true / true
      / 5 / 11 / true / world / 5 / yes / 22`) + 2 unit tests.
      397 unit / 81 CLI / 24-of-51 / roundtrips + component green.
      **Boundary:** `-> str` fns still take all-str params
      (`registerStrFunc`; a mixed `-> str` signature is the next
      slice); `s[a..b]` range sugar waits on range parsing; `+`
      concat of str values unwired (interpolation covers it); str
      methods on *literals* fold-or-reject via the const path;
      `String<R>` and the methods needing allocation-into-region
      (split, replace, …) wait on the collections story.


## Numeric tower — floats (f64 + f32 + narrow-int storage + native float-math builtins landed)

- [x] **The f64 floor, end-to-end.** Floats are first-class scalars now:
      FLOAT_LIT → `hir.float_const` (floats never const-fold — the
      evaluator stays integer/text-only; an f64 `let` goes straight to a
      typed runtime local), typed f64 `let`/`var` + compound assigns
      (`+= -= *= /=`; no `%=` — wasm has no float rem), arithmetic and
      comparisons (MIR `bin` picks the instruction family from operand
      type; `binOpF64` — `%`, bitwise, shifts honestly rejected),
      **no implicit int↔float conversion anywhere** (bin guard, call
      args, assigns, record fields — all reject mixing), f64
      params/returns (plain fns, fit methods), f64 struct fields (8/8
      layout), and printing/interpolation via a new `__fmt_f64` backend
      helper (sign, integer part, `.`, ≤6 fractional digits rounded
      half-up with carry, trailing zeros trimmed — `0.1 + 0.2` prints
      `0.3`; needs the universal nontrapping-fptoint feature, on in both
      address spaces). sema's `ScalarType` gained `.f64` with operand-
      recursive typing for arithmetic. Verified end-to-end wasm64 +
      wasm32 (link-roundtrip f64 section) + 2 unit tests incl. the
      rejections. **Boundaries:** NaN prints "0.0", |x| ≥ 2^64
      saturates (documented in `emitFmtF64`); f64 in `qview` host args
      and `q64 check`'s TYP042 float awareness untouched.
- [x] **f32 + the cast operators.** The cast form was already specced
      (types.md §Casts: function-call style, `f32(x)`/`f64(x)`/
      `i64(x)`; float→int narrowing **traps** — wasm's non-saturating
      trunc gives that for free), so no literal-suffix story was
      needed: a bare float literal is f64 (the spec default) and f32
      values come from casts and f32-typed params/returns/fields.
      Landed: `hir.num_cast` / `mir.num_cast` (target = inst type;
      backend picks promote/demote/convert/trunc by the (from, to)
      pair), `ScalarType.f32` with same-float-only mixing (f32+f64 is
      as rejected as float+int), `binOpF32` family, f32 params/
      returns on fns and fit methods, f32 struct fields at **4/4
      layout** (two f32s pack to size 8 align 4), and printing/
      interpolation promoting f32→f64 into the single `__fmt_f64`.
      Verified end-to-end wasm64 + wasm32 (link-roundtrip f32
      section) + 3 unit tests incl. the never-mix rejections.
      **Boundary:** `i64(x)` of an in-range float works; the full
      int tower (`i32(x)`, `u8(x)`, …) waits on those types existing;
      `try_into` waits on Result.
- [x] **Narrow integer storage (u8/i8/u16/i16/u32/i32).** The widths
      land as *storage* types — the honest floor while the spec leaves
      narrow arithmetic-overflow semantics (wrap vs trap) unpinned:
      struct fields at their natural width/alignment (3×u8 packs to
      size 3 align 1; `{i8, u16, u32}` lays out 0/2/4 → size 8 align
      4), in-range literal inits and field assigns (out-of-range →
      NotConstExpr, the build-time mirror of TYP040), width-true
      loads/stores (sign-/zero-extension into the i64 compute floor;
      MIR field ops carry explicit width+signedness now), formatting/
      interpolation of narrow reads, and explicit `i64(c.r)` widening.
      Narrow arithmetic, narrow bindings, and narrowing casts (`u8(x)`
      — needs the trapping range check) are rejected; records with
      narrow fields always materialize (SROA has no storage, so it
      would silently widen — caught as a boundary leak and locked).
      The golden program's `Color { r: u8 }` + `Display.fmt` shape
      runs end-to-end. Verified wasm64 + wasm32 (roundtrip narrow-int
      section) + 2 unit tests incl. the range/no-widening rejections.
- [x] **Native float-math builtins — `x.sqrt()`/`x.abs()`/`x.floor()`/
      `x.ceil()`.** The ops Wasm 3.0 ships natively, so they land now as
      builtins (the transcendentals below still need the `q64.math` stdlib).
      They parse as a dotted call on a float local (`x.sqrt()` → callee
      path `x.sqrt`), so `buildIntExpr`'s `.call` arm recognizes
      `floatBuiltinKind(method)` on an f64/f32 receiver (niladic) and emits a
      `hir.un` reusing the existing unary pipeline — `ops.UnKind` gained
      `fabs`/`fsqrt`/`ffloor`/`fceil`, `lower` types the result as the
      operand (like `neg`), and `emit`'s `.un` arm maps each to the
      `BinaryenAbs/Sqrt/Floor/CeilFloat{32,64}` instruction by operand type.
      `exprScalar.callRet` types `x.sqrt()` as the receiver's float type so
      it validates as a return/arg. Non-float receivers fall through (honest
      `NameNotFound`). Verified end-to-end wasm64 + wasm32
      (link-roundtrip float-math section: `4.0 / 3.5 / 2.0 / 3.0`) + a
      build_hir unit test. The **binary** builtins (`x.min(y)`/`x.max(y)`/
      `x.copysign(y)`) + `x.trunc()`/`x.nearest()` followed the same pattern:
      `ops.BinKind` gained `fmin`/`fmax`/`fcopysign` (`binOpF64`/`binOpF32`
      map them; the int `binOp` is `unreachable` — float-only), `UnKind`
      gained `ftrunc`/`fnearest`, and the `.call` arm recognizes a one-arg
      `x.min(y)` (rhs must be the same float type — no mixing) → a `hir.bin`.
      Verified wasm64 + wasm32 (roundtrip: `3.0 / 7.0 / -5.0 / 2.0`). The
      full native float-math surface (everything Wasm 3.0 has an instruction
      for) is now in. **Boundary:** receiver-*expression* forms
      (`make().sqrt()`) and float record fields as receivers aren't wired.
- [ ] **sin/cos/tan/exp/log → `q64.math` (decision recorded).** Wasm
      3.0 has no transcendental instructions (only `f64.sqrt`/`abs`/
      `ceil`/`floor`/`min`/`max`/`copysign` are native). Decision:
      software implementations in the `q64.math` stdlib qube —
      deterministic and portable, the libm-port approach — NOT host
      imports (per-host results would break determinism and force a
      capability disclosure on `@pure` math). Gated on stdlib qubes
      being loadable; `sqrt` can land earlier as a builtin since the
      instruction exists.

## Wasm 3.0 feature audit — DO BEFORE implementing concurrency

The Memory64 lesson (`/wasm` probe: WebKit has none → dual address space) has
not been applied to the rest of the platform bet. Everything in
`spec/concurrency.md` / `spec/streams.md` — and the one-scheduler invariant in
`spec/concurrency-model.md` — sits on **stack-switching**, which no production
engine ships; WebKit (the declared iPad baseline) also lacks threads-adjacent
pieces. Cheap insurance, do it before any scheduler code:

- [x] **Probe matrix — first pass recorded.** wasmtime column **probed**
      against vendored `wasmtime 45.0.0` via the C-API `wasmtime_config_wasm_*`
      toggles it exposes: tail-call ✓, exceptions ✓, gc ✓, function-references
      ✓, threads ✓ — **no `stack_switching` toggle** (only host-side
      `async`/`component_model_async_stackful` fibers, not guest `cont`/
      `resume`). Browser + wasmer columns from release-note knowledge as of
      2026-06 (NOT live-probed here — no browsers in the build env): tail-call/
      EH/GC broadly shipped; threads need COOP/COEP; **stack-switching ships
      nowhere on the floor**. Matrix recorded in `spec/memory.md`. **Still TODO:**
      the re-runnable `WebAssembly.validate` harness in `runtime/` to confirm
      the browser columns on real WebKit/iPad before declaring a host supported.
- [x] **Recorded the decision in the specs.** `spec/memory.md` §"Concurrency
      platform audit (the stack-switching reckoning)" holds the matrix +
      decision; the stale "stack-switching" platform bullet is corrected;
      `concurrency.md` and `concurrency-model.md` carry the v0-floor banner +
      cross-links.
- [x] **Picked the v0 concurrency floor: (b) single-threaded cooperative
      scheduler.** Suspension only at statically-known points (`await`,
      channel `send`/`recv`, suspending host calls — the effect system already
      identifies them), lowered as a **selective CPS / state-machine transform**
      of the suspendable functions (not whole-program asyncify). Rejected (a)
      "require a capable host" (excludes iPad) and (c) asyncify (taxes every
      function). Threads + guest stack-switching are opt-in capable-host
      *upgrades* behind the same one-scheduler abstraction. This **unblocks
      Phase 3**; `spawn`/`channel`/`select` codegen now targets this floor.
      (Recommendation pending maintainer sign-off; reversible at the spec level.)

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

- [x] **Decided: (1) hand-specced per-face wire ABIs for v0**, with
      the WIT migration path kept open (each face's wire section names
      its WIT interface — the same table `show world` uses). Captured
      in `spec/faces.md` §"Host ABI for capability faces". First
      concrete instance: **`env.fs.read` landed** (spec/env.md §"Wire
      ABI: fs.read") — `env.fs.read(path) -> str`, marks `@fs`, WIT
      lift imports `wasi:filesystem/*` automatically via the effect
      pass. Wire: `env.fs_read(dest, path_ptr, path_len) -> i64`
      (negative = failure → guest traps; the host **grows guest
      memory** for large files — verified with a 200KB read through
      3+ pages of growth). IR `fs_read` through HIR/MIR/effects/print;
      builder intercepts the dotted callee in buildStrExpr + isStrCall
      + the typing bridge; backend declares the import, raises
      `mem_max` when @fs is used, and emits the dest/len/trap/bump
      sequence; the wasmtime host implements the callback
      (introspected address width, like env.out). Verified end-to-end
      wasm64 + wasm32 (roundtrip fs.read section: contents / len /
      contains + the missing-file trap) + 1 unit test (HIR shape +
      @fs effect). 399 unit / 81 CLI / 24-of-51 / roundtrips +
      component green. **Boundary:** the `Result<Bytes, IoError>`
      form waits on str enum payloads (then `try env.fs.read(…)` and
      the golden fixture); writes (`fs.write`) and the browser host's
      fs face are later; v0 host grants @fs unconditionally (ENV030
      runtime denial later).
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
- [x] AST views: **complete** — every CST production the parser emits now
      has a typed view in `q64/src/parser/ast.zig`.
      • Items: `ast.Item` exposes `fn`/`struct`/`enum`/`type`/`const`/`face`/
        `fit` (visibility + name; struct `Field`s, enum `Variant`s, type
        `aliasedText`, const `value`).
      • Statements: `ast.Stmt` exposes `expr`/`let`/`return`/`assign`/`if`/
        `while`/`loop`/`for`/`match`/`break`/`continue`/`panic` (conditions,
        bodies, patterns, `MatchArm`s, assign target/value/op).
      • Expressions: `ast.Expr` exposes `bin`/`pipe`/`unary`/`try`/`call`/
        `index`/`field`/`method`/`tuple_field`/`question_dot`/`tuple`/`paren`/
        `array`/`path`/literals (operands, operators, args, elements).
      Codegen's exhaustive `Item`/`Stmt` switches gained `else` arms (it
      still lowers only the subset it understands).
- [x] **TypeExpr grammar (v0 floor).** Types are no longer raw spans:
      `parseType` (`parse.zig`) structures path (dotted name + raw
      `GenericArgs`), `ref`, slice/array, tuple, and optional, with a raw
      `TYPE_EXPR` fallback for fn/dyn/union. Wired into every type position
      (return type, params, fields, type/const/let). `ast.TypeExpr` exposes
      `path`/`ref`/`slice`/`array`/`tuple`/`optional`/`raw` with
      `PathType.name()` + `genericArgsText()`, element/inner/elements
      accessors, and `.text()`; `ReturnType`/`Param`/`Field`/`TypeDecl`
      gained `.type_()`. `.text()`/`typeText()` still work (`joinTokensAfter`
      now collects tokens recursively through the type node). Codegen is
      type-agnostic so it's unaffected; roundtrips green.
      **Deferred (parser-level):** structured generic args (`>>`-splitting),
      fn/dyn/union type structure, pattern destructuring internals,
      generic-param/effect/where internals, and the not-yet-parsed expr
      kinds (`record`/`range`/`lambda`/`spawn`/`channel`/`graph`).
- [x] **Compile-time integer arithmetic.** The resolver's `constEvalExpr`
      now folds integer expressions (`constEvalInt`): literals (decimal /
      `0x` / `0o` / `0b`, `_` separators), `+ - * / % & | ^ << >>`, unary
      `-`/`~`, parentheses, and bindings holding an integer. The decimal
      result renders into interpolation, so `env.out("{(1 + 2) * 3}")` →
      `9` and `let n = 6 * 7; "{n + 1}"` → `43`. Overflow / divide-by-zero
      aren't const-foldable (`NotConstExpr`). `link-roundtrip.sh` asserts
      `{(1+2)*3} {n+1} {1_000+24}` → `9 43 1024`.
- [x] **Runtime integer functions.** An `i64`-returning function whose body
      references a parameter (`fn double(n: i64) -> i64 { n + n }`) can't
      const-fold, so it's emitted for real: `ensureCallee` detects the i64
      return (via the structured `TypeExpr`), `emitIntExpr` lowers the body
      to wasm i64 arithmetic, the callee is `(i64×params) -> i64`, and the
      result is formatted by `__fmt_i64` — a wasm routine (a digit loop +
      sign handling) that writes decimal into the scope arena and returns
      `(ptr, len)`. `env.out(double(21))` → `42`, all at runtime. Verified
      end-to-end across 0 / negatives / multi-digit / multi-param;
      `link-roundtrip.sh` asserts `double(21)`/`add(1000000,234567)`/`neg(7)`
      → `42` / `1234567` / `-7`.
- [x] **Runtime i64 bindings + chaining.** `RtBinding` is now a str/int
      union: a `let x = double(21)` stores the i64 result in a single
      `_start` local (`bind_int_call`), `env.out(x)` formats it via
      `__fmt_i64` (`print_int_binding`), and an i64 binding can be passed as
      an argument to another i64 function (`ArgVal.int_local`), so
      `let a = double(21); env.out(add(a, 8))` → `50` and calls chain
      (`add(a, c)`). Binding locals are assigned by a running counter (str
      takes two, int one). Type mismatches (str arg to an i64 param or vice
      versa) are rejected. `link-roundtrip.sh` asserts the binding/chaining
      path → `50`. **Deferred:** `var` reassignment of an i64.
- [x] **i64 bindings interpolate into strings.** A new `int_binding` segment
      (a binding local formatted via `__fmt_i64`) is handled in the concat
      builder exactly like a `call` segment — it claims a tuple slot, the
      formatter runs once into the arena, and its `(ptr, len)` feeds both the
      length sum and the `memory.copy`. So `"a = {a}"` → `a = 42` and a single
      concat can mix a str binding and an i64 binding (`"{g} a is {a}"` →
      `hi! a is 42`). `link-roundtrip.sh` asserts `"{g}: a={a}, b={b}"` →
      `hi!: a=42, b=50`. **Deferred:** interpolating an i64 *call* result
      (`"{add(a, b)}"`) — the call path still extracts string args, so an i64
      call in interpolation is `UnsupportedCall`.
- [x] AST views (statements): `ast.Stmt` now surfaces `let`/`var`
      (`LetStmt`: `isVar`/`pattern`/`initializer`) and `return`
      (`ReturnStmt.value`) alongside `expr_stmt`, plus a `Pattern` view
      (`bindingName`), structured `ReturnType.text()`, and
      `Params.isEmpty()`. Codegen can now walk a binding-and-returning
      body; a `return`-bodied const fn (`fn version() -> str { return
      "0.1.0" }`) folds via `constEvalFn`. This is the prerequisite the
      "long pole" above was waiting on.
- [x] AST views (params): `parseParams` (`parse.zig`) now emits structured
      `PARAM` nodes (`ParamMode? IDENT ":" TypeExpr`); `ast.Params.iter()`
      yields `Param` views with `mode()` / `name()` / `typeText()`. Inner
      generic commas (`Map<K, V>`) don't split a param. Type stays a raw
      span (shared `joinTokensAfter` helper with `ReturnType.text`) until
      the type-expression grammar lands. Real (non-const-folded) callee
      emission now consumes this shape (ladder step 5). Cheap AST follow-ups
      when codegen demands them: surface the already-parsed
      `BIN_EXPR`/`UNARY_EXPR` in `ast.Expr` and the control-flow statements
      in `ast.Stmt` (just `cast` arms).
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
- [x] Parser: record/struct **expression** literals — done with ladder
      B1 (see the sema/struct ladder section): RECORD_EXPR + the
      Rust-style restriction, recorded in `grammar.md`.
- [x] `spec/concurrency-model.md` — the concurrency/reactivity consolidation
      chapter (the big remaining feature-review item): the global
      one-scheduler invariant + lowering table, the tasks vs actors vs
      graphs vs reactive-state decision table (QView owned by the reactive
      layer; twin = actor made normative), the `Signal` naming rule —
      `Signal` reserved for the rate-typed dataflow family, Stage-3 reactive
      primitives renamed `State<T>`/`Memo<T>`/`Watch`, `EventStream<T>`
      retired — and the closed bridge set between layers. Cross-edits:
      `reactivity.md`, `streams.md`, `concurrency.md`, `qview-protocol.md`,
      `spec/README.md` (+vocabulary), `stdlib/{reactive,event}/README.md`.
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

## Dual address space (wasm32 / wasm64) — NEW, SPEC LANDED

The `/wasm` probe on qubepods proved the floor: **Apple WebKit (Safari +
every iPad/iOS browser) has no Memory64 as of 2026.** The POC only "passed"
because it served a 32-bit Rust-built wasm — real `q64` output is 64-bit and
would not have run on iPad. So the address space is now an **explicit
per-build choice with no default** (decision recorded with the spec edits):
`wasm32` is the universal/WebKit baseline, `wasm64` adds Memory64 for capable
hosts. Specs updated: [`spec/memory.md`](./spec/memory.md) §"The platform" +
§"Address-space negotiation", [`spec/qube.json5.md`](./spec/qube.json5.md)
§Targets (`addressSpace` required), [`spec/q64-cli.md`](./spec/q64-cli.md) &
[`spec/qube-cli.md`](./spec/qube-cli.md) (`--addr`, per-`<addr>` output),
[`ARCHITECTURE.md`](./ARCHITECTURE.md), [`spec/continuum-api.md`](./spec/continuum-api.md).

Implementation:

- [x] **Backend: address space wired (wasm32).** `codegen/emit.zig` takes an
      `AddressSpace` (via `q64 emit --addr`); `wasm32` drops the Memory64 feature
      and sets a 32-bit memory. Values stay i64; only memory *addresses* differ.
- [x] **wasm32 string ABI — complete (Path B).** Pointer/length width is a
      backend knob (`ptr_type`: i32 on wasm32, i64 on wasm64), threaded through
      the **whole** string/arena ABI: `env.out`'s import + the data-segment
      offset, the `(ptr,len)` `pair_type`, the `sp` bump global, `__fmt_i64`
      (its cursor/arena pointers are ptr-width; the digit arithmetic stays i64),
      `emitConcat`, str values/params/bindings, and the buf/off/len scratch
      (`Lowerer.ptrConst`/`ptrGet`/`ptrAdd`). A new IR `ptr` type carries the
      str-binding pointer locals so `build_hir` no longer bakes i64 there. The
      `usesStrAbi` wasm32 gate is **removed** — string programs (str calls, int
      formatting, interpolation/concat, bindings) emit a genuine 32-bit module
      and **run on the WebKit/iPad baseline**. The wasmtime host is
      address-space-agnostic: it introspects `env.out`'s import (`envOutWantsI32`)
      to define a matching func type and reads each arg by runtime kind. Verified
      end-to-end in `link-roundtrip.sh` (the full `intfn` program — `42` / `q64
      v0.1.0 ok` / `hi!: a=42, b=50` — runs **identically** on wasm32 and wasm64)
      + emit unit tests; wasm64 unchanged.
- [x] **`q64` CLI: `--addr <wasm32|wasm64>`** on `q64 emit` (defaults wasm64
      to preserve existing string programs; `--addr wasm32` emits a genuine 32-bit
      module). Required/no-default policy lands with the Path-B string ABI.
- [ ] **`qube` CLI (build):** `addressSpace` required per target; build invokes
      `q64` once per address space; outputs under `target/<profile>/<addr>/`;
      `--addr` override; flag wasm64 builds as not-runnable-on-WebKit.
- [x] **`qube pod` CLI (deploy manifest):** `qube pod new`/`init` take
      `--addr <wasm32|wasm64>[,…]` and emit a `component.variants` map (per-addr
      paths derived from `--wasm`); legacy single-`wasm` is unchanged when
      `--addr` is omitted. `qube pod deploy` packs **every** declared variant
      into the bundle zip. Mirrors qubepods' `component.variants` schema; the
      generated manifest round-trips through `@qubepods/qubepod-schema`.
      (`qube/src/main.zig`, tests in `qube-test/tests/pod.test.ts`.)
- [decided] **Single linear memory (multi-memory is a non-goal for now).**
      Codegen emits one memory; the `mem.*` segregation in `spec/memory.md`
      stays aspirational. Bulk-memory ops are enabled.
- [x] **Runtime/glue:** the browser host (`runtime/web/app.js`, mirrored in the
      qubepods test page) probes Memory64 (`WebAssembly.validate` of a tiny
      `(memory i64 …)` module) and sends the `x-qube-addr` hint; `wasm32` is the fallback.
- [ ] **`q64 show memories`** reports the address space it emitted.
- [ ] **Continuum (optional, future):** additive prebuilt-artifact endpoint
      `/v1/qubes/{name}/{version}/artifact?addr=…` if the source registry
      should ever serve compiled variants (see continuum-api.md note).

## QView + reactive state + twins (architecture proof — NEW)

End-to-end POC, verified on iPad: q64 → wasm32 → WebGPU PWA + a q64-authored
backend twin. Design notes: [`spec/reactivity.md`](./spec/reactivity.md),
[`spec/agent-ui.md`](./spec/agent-ui.md).

Done:
- [x] **`qview` host face** — a `host_call` op lets q64 call
      `qview.text/number/button/present`; a client `screen.q` → wasm32 drives a
      WebGPU renderer (procedural SDF rounded-rect widgets + supersampled SDF
      text, retina-correct, retained node-id diff). Host in qubepods `apps/qview-demo`.
- [x] **Reactive `state`** — top-level `state x = <int>` → a mutable wasm global
      (`global_get`/`global_set`); exported screen handlers (`on_press`) mutate +
      redraw — a wasm-owned counter.
- [x] **Backend twin** — main-less modules + exported (mutable) state globals;
      `global.q` (`state count` + `pub fn inc()`) runs inside a Durable Object
      (qubepods `apps/qview-global`): shared `@state(app)` counter with WebSocket
      fan-out, cross-device, **scope = DO address** (user/app/room).
- [x] **`@state(app)` generation (v0)** — a generator emits the global app's q64
      source from `@state(app)` declarations (`apps/qview-global/gen-global.mjs`).

Remaining:
- [x] **wasm32 string ABI** — done (see "Dual address space" above): the full
      string/arena ABI is address-width, so string programs run on WebKit/iPad.
      The browser host glue (`runtime/web`, qubepods) still needs to read the
      i32 `env.out` args to exercise it in a real PWA (the wasmtime host already
      does); that's the remaining host-side wiring.
- **`screen`/`draw` DSL** as real q64 syntax (the frontend language).
  - [x] **Parse + AST (the design + parse slice).** New keywords `screen` /
        `draw` / `on`; grammar `ScreenDecl := "screen" IDENT? "{" (StateDecl |
        DrawBlock | OnHandler)* "}"`, `DrawBlock := "draw" Block`, `OnHandler :=
        "on" IDENT Params? Block` (spec/grammar.md). Parser production
        (`parseScreenDecl`/`parseDrawBlock`/`parseOnHandler`, reusing the
        existing Block/Params/StateDecl grammar), `ast.ScreenDecl`/`DrawBlock`/
        `OnHandler` views (+ a generic `ChildIter`), wired into `ast.Item`.
        Lossless round-trip + structure tests; no corpus conflict (`on`/`draw`/
        `screen` appear only in comments today). `q64 check` on a screen file is
        clean.
  - [ ] **Lowering.** `build_hir` synthesizes `main` (the `draw` block's widget
        calls + `qview.present()`) and an exported handler per `on <event>`
        (its body + re-emit the `draw` block + present — Stage-1 auto-redraw),
        resolving bare widget calls (`text(…)`) to `qview.*` host calls and the
        screen's `state` to the reactive globals. Then a real screen `.q` emits
        to the same wasm the hand-written `qview.*` form does today.
  - [ ] **`@state(scope)`** syntax + AST partitioning (client reads→subscribe,
        writes→command) builds on this.
- [ ] **`@state(scope)`** first-class syntax + a twin `face`/RPC API (typed
      methods beyond `inc`).
- [ ] **MSDF** text (corner-perfect) + the full retained `Renderer` face
      (`create_node`/`set_attr`/`mutate`).

## Conventions

- Tick `[x]` when done. Strike through and leave the line until the
  next sweep so we have a trail.
- Keep items terse — link to the spec / file / commit rather than
  re-explaining context here.
- New items append to "Other open items" by default; pull out into a
  named section when more than a few related items accumulate (as
  C bindings has).
