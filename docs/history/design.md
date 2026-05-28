# q64 — Design Summary

A draft of design decisions reached through discussion. Not a specification — a captured snapshot of intent, suitable for refinement into a real spec.

## Identity

- **Language name:** q64
- **Site:** q64.dev
- **CLI binaries:** `q64` (language tool) and `qube` (package/build tool)
- **Build/package tool:** `qube`
- **Manifest:** `qube.json5`
- **File extension:** `.q`
- **License:** MIT
- **Tagline (working):** A stream-first language for Wasm 3.0, with managed and unmanaged memory as first-class peers.

## The Bet

q64 is shaped by a few committing decisions that compound:

1. **Target Wasm 3.0 exclusively.** Not native, not Wasm 1.0, not Wasm with optional GC. Wasm 3.0 with all its features assumed available.
1. **64-bit only.** Memory64, table64, `i64` pointers throughout. No 32-bit Wasm path.
1. **Managed and unmanaged memory both first-class.** Linear memory (allocator-managed) and WasmGC references coexist; the type system enforces the boundary.
1. **Streams as the primary abstraction.** Audio, tensors, ECS queries, AI tokens, UI reactivity — all instances of typed dataflow graphs.
1. **No GC required at the language level.** GC is available but opt-in; the default is region-based unmanaged memory.

These constraints determine almost everything else.

## Memory Model

### Two heaps

- **Linear memory:** carved up by allocators, pointer-based (`i64`), explicit lifetime, lowers to Wasm linear memory.
- **Managed memory:** WasmGC references, opaque, engine-collected, lowers to Wasm GC types.

The heaps are disjoint at the platform level. Crossing between them requires explicit copying.

### Regions

The unifying abstraction. A *region* is an allocator with a lifetime and a policy.

- Regions can be linear (arena, pool, stack, free-list) or managed (GC).
- Scopes own regions; tasks borrow regions from their scope.
- The type system tracks which region a value lives in.
- Values from different region kinds are different types; conversion is explicit.

The one-sentence rule: **Allocate from a region; the region’s policy determines lifetime, layout, and concurrency rules.**

### Default

Linear is the default. Scopes provide an arena by default. `managed` marks types/regions that live in the GC heap. No `unsafe` keyword for the dual of managed — manual memory is not considered unsafe in q64; it’s the normal case.

Full detail of region kinds, multi-memory layout, lifetime tracking, cross-heap transfers, and the memory-concurrency interplay lives in `memory.md`.

## Concurrency

### The boundary rule

Every concurrency model is determined by what crosses thread boundaries and under what rules. q64’s answer: **ownership transfer with structured scopes**.

- Tasks belong to scopes; scopes own allocators and tasks.
- Tasks cannot outlive their scope.
- Values cross between tasks via channels with ownership transfer (move semantics).
- Shared state is opt-in via a `Shared[T]` type or explicit shared regions.
- Compile-time race freedom via `Send`-like markers.

### Threading on Wasm

- Threading is a host concern, not a language concern.
- The host provides OS threads (or Web Workers); q64 schedules tasks across them.
- Shared linear memory + atomics + wait/notify for cross-thread coordination.
- Stack-switching primitives (Wasm 3.0) implement task suspension within a thread.

### The SAB story

SharedArrayBuffer, Web Workers, COOP/COEP headers, `postMessage`, `Atomics.wait` — all hidden behind the runtime adapter. User code sees scopes, tasks, channels. The adapter translates to platform primitives.

Deployment configuration (COOP/COEP headers) and host affinity for special sinks (audio worklets, main-thread UI) remain visible because they reflect real platform constraints. Everything else disappears into the runtime.

### The stream runtime *is* the async runtime

In a stream-first language, async isn’t a separate feature. The stream graph executor handles task scheduling, suspension via stack-switching, channel waits, and backpressure. One-shot computations are a degenerate case of streams.

## Streams, Signals, Events

The core dataflow vocabulary, type-distinguished:

- **`Stream[T]`** — typed sequence with a temporal contract (continuous, discrete, or sampled).
- **`Signal[T]`** — continuous; always has a current value. `Time → T`.
- **`Event[T]`** — discrete; exists at specific moments. `[(Time, T)]`.

Explicit conversion primitives:

- `signal.changes()` → event stream of value changes
- `events.hold(initial)` → signal latching the last event value
- `events.fold(seed, f)` → signal accumulating event history
- `signal.sample(events)` → event stream of signal values at event times

### Synchronous time

Time advances in discrete logical ticks. Within a tick, all simultaneous changes are coherent (no glitches). Feedback cycles require an explicit `pre` (one-tick-delay) operator. Inspired by Lustre, applicable to audio, control, simulation, UI.

### Stream graphs as language feature

- A `stage` is a unit that consumes streams and produces streams.
- A `graph` composes stages into a dataflow network.
- The compiler sees the graph statically and can fuse, schedule, parallelize.
- Effects on stages (`@realtime`, `@no_alloc`, `@pure`) propagate through the graph.

### Cross-thread streams

Signals don’t cross threads directly — they’re thread-local by nature. To send across threads, sample to events, transmit via channel, hold on the other side. The type system enforces this; conversion is named.

Channel backing typically uses preallocated slot buffers (ring buffers or triple-buffering for large signal values), owned by the channel, not by either thread.

## Effects

A checked effect system tracking properties of functions and stream stages:

- **`@realtime`** — no allocation, bounded execution time, no blocking. Real-time-safe.
- **`@pure`** — no mutation, no observable side effects.
- **`@no_alloc`** — no heap allocation (linear or managed).
- **`@io`** — performs I/O.
- **`@network`** — performs network operations.
- Capability-style effects can be added as needed; effects compose through call graphs.

Effects are statically checked. Real-time stages cannot call non-real-time functions. The registry can surface effect requirements per package, enabling capability-aware dependency disclosure.

## Type System

### Highlights

- Statically typed, type inference at local-let level (Swift/Rust style).
- Generic types with const generic parameters (for sizes, sample rates).
- Region parameters on types (`Vec[T, R]`).
- Tagged unions (sum types) as first-class.
- Pattern matching as expressions.
- Trait/protocol-like interfaces.
- Comptime evaluation for code generation.

### Numeric types

The canonical numeric alphabet:

- Signed integers: `i8`, `i16`, `i32`, `i64`. Default int is `i64`.
- Unsigned integers: `u8`, `u16`, `u32`, `u64`.
- Floats: `f16`, `f32`, `f64`. Default float is `f64`.
- `bool` is a distinct type, not an integer.

No `usize`/`isize` — q64 is 64-bit only, so pointers are always `i64` and a separate pointer-sized name is redundant. A direct dividend of the Wasm-64 commitment.

**Arbitrary-width integers** (Zig-style) are available for bit-level work: `u1`, `u3`, `u24`, `i17`. Useful for packed structs, protocol parsing, register layouts, sample formats. The compiler emits the masks/shifts on top of `i32`/`i64`. Opt-in feature; canonical code uses the fixed widths above.

**SIMD** is exposed as typed lane vectors: `Simd[f32, 4]`, `Simd[i16, 8]`. The lane type and count are part of the type — units-of-measure thinking applied to vector lanes. Raw Wasm `v128` is not surfaced.

Names follow Rust's `<letter><width>` shape; widths follow Zig's flexibility. The signed/unsigned distinction lives in the type, not in the operation (unlike Wasm itself, where ops carry the signedness).

### Units as types

Quantities carry their unit in their type. Dimensional analysis at compile time:

- Linear: `Hz`, `Samples`, `Seconds`, `Bytes`.
- Logarithmic: `Db`, `Semitones`, `Cents`.
- Operations enforce dimensional consistency.
- Conversions are explicit and ergonomic.
- Literal syntax: `48.kHz`, `-6.dB`, `1024.samples`, `120.bpm`. SI casing in literal suffixes (lowercase `d` for the deci- prefix, uppercase `B` for Bel).

This catches sample-rate mismatches, gain-vs-linear confusion, buffer-size-vs-byte-size errors at compile time. Extends to tensor shape checking and other domain-specific quantities.

### Parameter modes (from C#, extended)

Function parameters carry an explicit mode visible at signature and call site:

- **`in`** — immutable borrow (default if no keyword).
- **`ref`** — mutable borrow.
- **`out`** — function writes; caller’s prior contents irrelevant; must be assigned before return.
- **`move`** — function takes ownership; caller cannot use after.

Call sites repeat the keyword: `process(in: signal, ref: state, out: result, move: payload)`.

## Annotations

Three categories of `@`-annotation:

1. **Compiler-known markers** (lowercase): `@realtime`, `@pure`, `@inline`, `@deprecated`, `@public`, `@test`. Built into the language; affect type checking, codegen, visibility.
1. **Derive-based code generation**: `@derive(Json, Hash, Debug)`. Comptime functions that generate trait impls based on type structure. User-extensible.
1. **Property/declaration wrappers** (PascalCase): `@Signal`, `@Event`, `@Stream`, `@Atomic`, `@Lazy`. Transform field declarations into elaborated forms. User-extensible via comptime.

Casing convention disambiguates the categories visually.

## Syntax Lineage

Primary aesthetic: **Swift and C# readability** for systems-leaning semantics.

Borrowings:

- **From Swift:** argument labels, property wrappers, result builders for graph DSL, trailing closures, `borrowing`/`consuming`/`inout` semantics, structured concurrency feel.
- **From C#:** `in`/`out`/`ref` parameter modes, `using` for scopes, records, switch expressions, nullable `T?`.
- **From Zig:** explicit allocator parameters as cultural pattern, comptime blocks.
- **From F#:** units of measure precedent.
- **From Rust:** overall structure (`fn`, `struct`, `enum`, attributes), trait-like interfaces.
- **From F#/Elixir:** pipe operator `|>` for stream pipelines.
- **From Hylo:** value semantics influence.

Diverges from Rust deliberately in keywords and semantics to avoid the “looks like Rust, isn’t Rust” trap.

Full treatment with rationale, what each influence contributes and what q64 declines, plus Julia, Lustre, the structured-concurrency lineage, and notable absences: `influences.md`.

## Endianness

q64 is little-endian, period. Wasm mandates it; q64 documents it as part of the language spec, not as a target-dependent fact. External data formats (network protocols, file formats) handled via explicit `read_u32_le` / `read_u32_be` style accessors.

## Build Tools: q64 and qube

Two CLI binaries, each with a clear scope.

### `q64` — the language tool

Operates on q64 *source* (single files, the language server). Project-level operations live in `qube`.

```
q64 file.q                 # compile-and-run a single source file
q64 run file.q             # explicit form of the above
q64 build file.q           # emit a .wasm artifact to disk
q64 fmt [path]             # format
q64 lsp                    # language server (stdin/stdout LSP)
q64 show types <expr>      # introspection
q64 show effects <fn>
q64 show regions <fn>
q64 show graph <stage>
```

### `qube` — the package and build tool

Operates on qube *projects* (directories with a `qube.json5` manifest). Internally invokes `q64` per source file, the same way `cargo` invokes `rustc`.

```
qube new myproject
qube init
qube add qaudio
qube remove qaudio
qube build
qube run
qube test
qube install
qube lock
qube publish
qube outdated
qube audit
```

The split mirrors `rustc` + `cargo`: source-level work in one binary, project-level work in the other. The package unit itself is called a **qube** — `qube.json5` describes one, the registry stores them, the `qube` binary is what you reach for to operate on them.

### Manifest: qube.json5

JSON5 format with published JSON Schema. Every manifest starts with `$schema` reference for free editor tooling.

Static configuration (dependencies, targets, metadata) lives in `qube.json5`. The optional `build.q` provides imperative escape hatch for projects that need computed configuration.

### Targets

q64 supports multiple Wasm hosts via target profiles in the manifest:

- `browser` (with dev server handling COOP/COEP, hot reload, source maps)
- `wasmtime` (native server-side)
- `wasmer`
- `audio-host` (VST3, AU, AAX via host adapters)
- Custom hosts

`qube build --target <name>` produces the appropriate output.

### Lock file

`qube.lock` ensures reproducible builds. Committed for applications, debated for libraries (Cargo convention).

### Capability disclosure

The package registry surfaces effect requirements per qube. `qube add somepackage` reports what effects the qube transitively uses. Effects + registry = capability-aware ecosystem.

## Compilation Pipeline

```
q64 source (.q)
    │
q64 compiler (no LLVM dependency)
    │
    ├──→ direct Wasm 3.0 emission (via Binaryen or custom backend)
    │
    │ alternatively, MLIR-Wasm dialect path for advanced optimization
    │
.wasm + runtime adapter (JS for browsers, native for Wasmtime, etc.)
    │
Execution on target host
```

No LLVM. Either direct emission via Binaryen’s C API or future MLIR-native Wasm dialect path. Targeting Wasm 3.0 directly is faster than going through LLVM and avoids LLVM’s lag on high-level Wasm features.

## Inspection and Introspection

q64 has no VM, so introspection is *designed*, not *automatic*:

- **Compile-time queries:** rich. The compiler answers questions about types, regions, effects, graph topology, layouts, latency, resource bounds. Exposed via `q64 show ...` commands and via comptime.
- **Link-time queries:** structured. Custom Wasm sections carry graph topology, effect declarations, capability needs.
- **Runtime queries from inside:** explicit. Only what the runtime maintains is queryable (task registry, stream graph as first-class value, region stats).
- **Runtime queries from outside:** via standard Wasm debugging protocols, source maps, engine APIs.

JSON parsing and similar generic-over-types code is handled via comptime derive, not runtime reflection.

## Standard Library Direction

To be designed in detail, but principles:

- Collections parameterized over region (`Vec[T, R]`, `Map[K, V, R]`).
- Both linear and managed versions of fundamental types.
- Streams, signals, events as first-class types with full operator set.
- Channels with multiple policies (latest-value, ring buffer, lossless backpressure).
- Units of measure types (`Hz`, `Db`, `Samples`, etc.) in stdlib.
- I/O abstracted as a passed value (Zig influence), not ambient.

## Open Questions

Items intentionally left for later design:

- Pipe operator (`|>`) and stream graph syntax in detail.
- Pattern matching syntax in detail.
- Error handling model (result types, exceptions, both?).
- Module system and visibility rules.
- Concrete syntax for region parameters in types.
- Stdlib collection type design.
- JS interop: the runtime adapter’s API surface.
- WASI integration strategy.
- Debugging story (source maps, debug info, IDE integration).
- Hot reload protocol.
- Plugin system for build-time extensions.

## Design Principles

A few that recur across decisions:

1. **Make invisible distinctions visible in the type system.** Hz vs. samples, signal vs. event, managed vs. unmanaged, real-time vs. unrestricted — surface these.
1. **Default to the common case; opt in to the exception.** Linear memory by default; GC when needed. Borrowed parameters by default; move when needed.
1. **Boundary crossings are explicit and named.** Region conversions, thread crossings, heap conversions, unit conversions — all named operations.
1. **Effects are first-class.** Real-time, allocation, I/O, purity — all checked at compile time.
1. **No hidden complexity at the platform boundary.** Hide SAB, COOP/COEP, Worker bootstrap, BigInt marshaling. Surface only what’s semantically meaningful.
1. **The compiler is queryable.** What it knows, the programmer can ask.
1. **Cargo-shaped tooling, modern formats.** `qube` for packaging, `q64` for the language; JSON5 for the manifest; two purpose-built CLI binaries.
1. **Wasm 3.0 is the platform, not a backend.** Design assumes Wasm 3.0’s full feature set; doesn’t compromise to fit older Wasm or native targets.

-----

*This document captures a design conversation. It is not a specification. Many details require working through before any of this becomes implementable. The next step is likely a smaller, more focused spec for one concrete area (probably the type system or the stream/region semantics) that can be prototyped.*
