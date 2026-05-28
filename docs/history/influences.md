# q64 — Influences

What q64 borrows, from where, and what it declines. design.md has a one-paragraph "Syntax Lineage" section; this file is the full treatment, with the rationale for each adoption (and each refusal).

q64 isn't novel for novelty's sake. Almost every design decision is a deliberate choice from a small menu of options that other languages have already explored. Knowing where each piece comes from makes the decisions reviewable rather than arbitrary.

## The platform: Wasm 3.0

Not a language, but the most determining influence. Wasm 3.0 in 64-bit mode shapes everything: Memory64 makes `i64` pointers the natural width; multiple memories let region kinds map to distinct linear memory instances; WasmGC gives us a managed heap without writing a collector; stack-switching enables virtual threads without function coloring; threads + atomics make shared linear memory tractable.

q64 doesn't try to support older Wasm or native targets. The whole language design assumes Wasm 3.0's full feature set is available. This is the "Wasm 3.0 is the platform, not a backend" principle from design.md.

## Rust — overall structure

What q64 takes:
- Keywords: `fn`, `struct`, `enum`, attributes
- Ownership + move semantics for linear memory
- Trait-like interfaces (q64 calls them traits/protocols)
- `Result[T, E]`, `Option[T]` shape for error and absence
- Tagged unions (sum types) as first-class
- Pattern matching as expressions
- The fixed-size array shorthand `[T; N]` and `[expr; N]`
- The repr-name convention `i8…i64`, `u8…u64`, `f32`, `f64`
- Const generics for sizes and other compile-time numbers
- Newtype pattern (q64 generalizes this to `@kind`)

What q64 declines:
- Lifetime annotations as visible syntax — q64 uses region parameters and scope-bound lifetimes, fewer explicit annotations on common code
- The trait coherence rules in their full strictness — q64's `@kind` and multi-parameter traits relax some of Rust's orphan rule
- `unsafe` blocks — manual memory in q64 is not "unsafe," it's the normal case
- Macro syntax `macro_rules!` and proc-macros — q64 uses comptime instead

Diverges from Rust deliberately in keywords and semantics to avoid the "looks like Rust, isn't Rust" trap. Region parameters appear where lifetimes would; return-type separator is `:` not `->`; no function coloring (no `async fn`).

## Swift — readability and concurrency feel

What q64 takes:
- Argument labels at call sites where they clarify intent
- Property wrappers (`@Signal`, `@Event`, `@Stream`, `@Atomic`, `@Lazy`)
- Result-builder DSL pattern for the stream graph syntax
- Trailing closures for higher-order calls
- `borrowing`, `consuming`, `inout` semantics merged with C#-style `in`/`ref`/`out`/`move` keywords
- Structured concurrency feel: `scope { ... }` mirrors `TaskGroup { ... }`
- Implicit `return` for single-expression function bodies

What q64 declines:
- `class` vs `struct` distinction with reference/value semantics depending on declaration — q64 expresses this via region kind (managed vs linear), not via type-kind
- Protocols as both interfaces *and* existentials — q64 separates the two
- Optionals `T?` as language sugar over an enum — q64 keeps it, but the underlying machinery is just a sum type

Swift is the strongest single influence on q64's *feel*. The goal is "Swift readability, systems-leaning semantics."

## C# — parameter modes

What q64 takes:
- `in`, `ref`, `out`, `move` as explicit parameter modes, visible at both signature and call site
- `using` for scope-bound resources, generalized to `scope { ... }`
- Records (immutable-by-default value types with structural equality)
- Switch expressions returning values
- Nullable `T?` with explicit handling
- String interpolation `"{x}"` syntax style

What q64 declines:
- The whole .NET runtime / CLR
- Reference vs value type as a property of the type declaration — q64 uses the region kind for this
- Generic variance annotations as a top-level concern

C# contributed the parameter mode design specifically. Forcing the call site to repeat `in:` / `ref:` / `out:` / `move:` makes the data flow visible at every invocation.

## Zig — allocator culture and comptime

What q64 takes:
- "Anything that allocates takes the allocator as an explicit parameter" — generalized to regions
- Comptime blocks and comptime parameters
- Arbitrary-width integers (`u3`, `u24`, `i17`) for bit-level work
- The cultural pattern of preferring explicit over implicit, even when it costs ergonomics
- Tagged unions with payload, no inheritance

What q64 declines:
- Defer statements — q64's scope-bound regions handle most defer-style cleanup automatically
- C ABI as a first-class goal — q64 targets Wasm; C interop happens through the runtime adapter, not the language
- `comptime` as a top-level keyword on every comptime use — q64 makes comptime a property of parameters and blocks rather than a sigil at every site

The Zig contribution is largely *cultural*: explicit allocators, comptime as the general metaprogramming tool, arbitrary-width integers as a normal feature. q64 absorbs the culture more than the syntax.

## F# — units of measure

What q64 takes:
- Units of measure as types, with dimensional analysis at compile time (`Hz`, `Seconds`, `Bytes`, `Db`, `Semitones`)
- Literal syntax `48.kHz`, `-6.dB`, `120.bpm`
- The pipe operator `|>` (shared with Elixir)
- Type inference at let-bindings, no top-level inference (Swift/Rust style, originally F#)

What q64 declines:
- The .NET runtime
- ML-family syntax (currying everywhere, `let` everywhere) — q64 takes Swift/Rust shape
- Computation expressions as the general extension point — q64 uses comptime + property wrappers instead

The F# contribution is concentrated on the type-level numeric work. The units-of-measure precedent is rare in mainstream languages, and q64 leans on it heavily for audio, signal processing, and 3D math.

## Julia — math readability and broadcasting

What q64 takes:
- **Broadcasting dot**: `a .+ b`, `f.(xs)` — elementwise ops and map visible at the call site rather than guessed from shapes. Cleaner than NumPy's implicit broadcasting; q64 makes broadcast compatibility a comptime predicate.
- **Unicode identifiers**: `α`, `β`, `π`, `σ`, `λ`, `ε`, `θ` in code. Math-heavy domains (DSP, 3D, ML, scientific) earn dramatic readability wins when code matches the printed math.
- **Multi-parameter trait dispatch**: not full multimethods, but `trait Convert[From, To]` with `impl Convert[PCM[i16], PCM[f32]]`-style implementations covers the boundary-crossing operations (format conversions, color space conversions, vocab translations) with one uniform API.
- **Numeric promotion rules**: `promote_rule(Int, Float) = Float`-style declarative tables for what type `1 + 1.0` produces. Adopted for the numeric tower and unit-of-measure interactions.
- **Abstract numeric hierarchy**: `Number` → `Real` → `Integer` → `Signed` etc. as a trait hierarchy. Lets generic code target the right level.
- **Linear algebra API style**: `A \ b` for solve, lazy transposes, matrix-as-operator. Borrowed in `q64.math`.
- **Convenience numerics in stdlib**: `Complex[T]`, `Rational[T]`, `BigInt`, `BigFloat` — math-heavy domains need these and they belong in stdlib, not packages.
- **Type-stable code as the perf model**: when the compiler knows every type, you get C-class codegen. q64 is statically typed so this is built in; the cultural lesson is to give users tools to see type stability (`q64 show types <expr>`).

What q64 declines:
- Dynamic typing with JIT inference — q64 commits to static-with-inference, AOT compilation
- Garbage collection by default — q64 is dual-heap with linear as default
- JIT specialization per call site — q64 specializes at compile time via comptime and monomorphization
- Pure multimethods at the language level — q64 uses traits/protocols with multi-parameter dispatch instead
- Method redefinition at runtime — q64's hot-reload story is separate and bounded

Julia's deepest commitment is *make math-heavy code as readable as the paper it implements*. q64 shares that target audience and that commitment.

## Lustre — synchronous time and dataflow

What q64 takes:
- The synchronous-tick model: time advances in discrete logical ticks; within a tick, all simultaneous changes are coherent (no glitches)
- Explicit `pre` (one-tick-delay) operator for feedback cycles in dataflow graphs
- The premise that dataflow graphs are statically analyzable — type-check the graph, schedule the graph, compile the graph

What q64 declines:
- Lustre's narrow synchronous-only focus — q64 is general-purpose, with the stream graph as one model among several
- The specific syntax — Lustre is mathematical/textual; q64 uses Swift-flavored DSL syntax

Lustre is the precedent that says "dataflow with synchronous time is *implementable* and *correct-by-construction*." q64 takes that, generalizes it to audio + ECS + UI + AI tokens + control, and ties it to the stream/signal/event vocabulary.

## Structured concurrency lineage — Swift, Trio, Kotlin, Loom

What q64 takes:
- Structured scopes (Swift's `TaskGroup`, Trio's nursery, Kotlin's `coroutineScope`) — every task lives in a scope; scope cannot exit until all child tasks complete
- Cancellation propagation from parent scope to children
- Virtual threads via stack-switching (Java Project Loom, Go goroutines, Erlang processes) — the M:N scheduling model

What q64 declines:
- Coloring (`async fn` / `await` syntax) — Wasm 3.0 stack-switching lets us avoid it
- Cancellation as exceptions thrown at await points — q64 uses cooperative cancellation observed via `ctx.cancelled()`

The structured-concurrency lineage was developed across multiple languages independently between roughly 2017–2021. q64 adopts the converged answer.

## Hylo — value semantics

What q64 takes:
- Value semantics influence: most types are values, references are explicit and bounded
- Mutation through explicit parameter modes rather than ambient reference aliasing

What q64 declines:
- Hylo's subscript/projection model in full — q64 keeps a more conventional method-call surface
- The whole "mutable value semantics" research framing — q64 absorbs the principle without adopting the academic apparatus

Hylo is a quieter influence than the others — it confirmed that value semantics + explicit mutation works as a general model, beyond Rust's specific take.

## Elixir / Erlang — pipes and supervision

What q64 takes (Elixir):
- Pipe operator `|>` for stream pipelines (also shared with F#)
- The pipe as a *forwarding* operator, not a function-composition operator

What q64 takes (Erlang OTP):
- The actor pattern as a robust concurrency primitive
- Supervision hierarchies as a recovery model — partially absorbed into structured scopes (parent scope unwinds on child task panic)

What q64 declines:
- The BEAM virtual machine
- Soft real-time scheduling as a runtime feature — q64 makes `@realtime` a *type-level* property, checked at compile time

## Notable absences

Worth being explicit about what q64 deliberately doesn't borrow from:

- **Haskell**: pure functional programming, monadic effects, type-class hierarchies of extreme generality. q64 keeps it simple — strict evaluation, traits over typeclasses, effects as a small fixed set of compile-time-checkable markers.
- **Python**: dynamic typing, indentation as syntax, runtime monkey-patching. q64 is statically typed, brace-delimited, AOT.
- **C++**: undefined behavior, templates-as-error-machine, multiple-inheritance, the preprocessor. q64 has no UB in safe code, comptime instead of templates, single trait inheritance, no preprocessor.
- **JavaScript**: implicit type coercion, prototype chains, `==` vs `===`, ambient globals. q64 has explicit conversions, no inheritance hierarchy on values, one equality operator, capabilities passed as values.
- **C# / .NET runtime**: the CLR itself. q64 takes language features from C# but not the runtime — Wasm is the platform.
- **Go**: the lack of generics in early Go; the panic-and-recover model as a substitute for proper error handling. q64 takes structured concurrency from Go's goroutine model but expresses errors as values (`Result[T, E]`) and supports proper generics.
- **Scala / Kotlin**: full subtyping with variance annotations as a frontline concern. q64 keeps the trait/protocol surface uniform; variance shows up only where strictly needed.

## The synthesis

q64 is not the sum of these influences — it's their intersection on a particular platform (Wasm 3.0 in 64-bit mode) for particular use cases (audio, 3D, ML inference, real-time UI, browser-resident applications). The places where q64 is distinctive are mostly:

- **Streams/signals/events as language types** rather than stdlib types — Lustre's idea generalized
- **Region kinds in the type system** — combining Zig's allocator culture, Rust's ownership, and Wasm 3.0's multiple memories
- **Effects as a small fixed set of compile-time-checked markers** — distilled from research effect systems into a practical kit
- **Dual heap with linear as default, managed as opt-in** — the Wasm 3.0 dividend, not borrowed from any single language
- **No function coloring** — only possible because of Wasm 3.0 stack-switching; sidesteps the async/await debt of every other language that has it

Each individual borrowing is unoriginal. The shape of the whole comes from picking which borrowings compose, and committing to the Wasm 3.0 platform as the substrate that makes them composable.
