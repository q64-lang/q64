# q64 — Memory Model

How memory is organized in q64, with Wasm 3.0 in 64-bit mode as the platform substrate. Expands on design.md's Memory Model section with the detail needed to actually implement and use the system, including the interaction with concurrency.

## The platform: Wasm 3.0 in 64-bit mode

q64 commits to these Wasm 3.0 features unconditionally:

- **Memory64**: 64-bit linear-memory addressing. Pointers are `i64`; address space is effectively up to 2^48 (host-dependent).
- **Multiple memories**: a module can declare and use several linear memory instances. q64 uses this to segregate region kinds at the platform level.
- **WasmGC**: managed references, `struct.new`, `array.new`, engine-managed collection. A separate heap from linear memory.
- **Table64**: 64-bit reference tables for GC references and function pointers.
- **Threads + atomics**: SAB-backed shared linear memory and atomic ops.
- **Stack-switching**: lightweight coroutine stacks.

These choices compound. Memory64 + multiple memories + WasmGC + threads means the dual-heap model can be implemented natively instead of emulated, and multiple memories can be assigned to distinct purposes rather than crammed into one buffer.

## The two heaps

**Linear memory**:

- Carved up by allocators.
- Pointer-based (`i64`).
- Explicit lifetime (a region owns the bytes; the region frees them).
- Lowers directly to Wasm linear memory.
- Can be shared across threads via SAB.

**Managed memory**:

- WasmGC references, opaque to user code.
- Engine-collected — no explicit free.
- Lowers to Wasm GC types (`struct.new`, `array.new`, `ref` types).
- Cannot be shared across threads — the GC arena is per-Wasm-instance (per-Worker in the browser).

The heaps are **disjoint at the platform level**. Wasm 3.0 gives us separate instructions and separate memory areas. Crossing between them in q64 requires explicit copying — there is no implicit pointer-to-reference conversion, and the type system prevents one accidentally.

## Regions

The unifying abstraction. A *region* is an allocator with a lifetime and a policy.

```q64
scope { ... }                              // owns an arena by default
region rt: Arena[1.MB] { ... }             // explicit named arena
region pool: Pool[Frame, 64] { ... }       // typed slot pool, fixed capacity
shared_region world { ... }                // SAB-backed shared region
region gc: Managed { ... }                 // GC heap handle
```

Every region has:

- A **kind** (arena, pool, stack, free-list, managed).
- A **lifetime** (typically tied to a scope or task).
- A **policy** (single-task, shared, lock-free).
- A **backing memory** — one of the module's linear memories, or the WasmGC heap.

The type system tracks which region a value lives in. Values from different region kinds are different types; conversion is explicit.

Rule: **allocate from a region; the region's policy determines lifetime, layout, and concurrency rules.**

### Region kinds

| Kind          | Allocator        | Free strategy           | Concurrency                | Typical use                          |
|---------------|------------------|-------------------------|----------------------------|--------------------------------------|
| Arena (bump)  | bump pointer     | all at scope exit       | single-task only           | per-request, per-frame, per-tick     |
| Pool          | fixed slot index | individual or scope     | lock-free with reservation | message queues, frame pools          |
| Stack         | LIFO             | implicit on return      | strictly per-task          | local temporary buffers              |
| Free-list     | malloc-style     | individual              | single-task or locked      | general-purpose dynamic memory       |
| Managed (GC)  | engine           | engine, async           | per-Wasm-instance          | long-lived graphs, cyclic structures |

Arena is the cheapest (one pointer bump per allocation); managed is the most flexible (cycles, no manual lifetime tracking) at the cost of an engine collector running occasionally.

## Region parameters in types

Collections and other allocating types carry their region as a type parameter:

```q64
Vec[T, R]          // growable array in region R
Map[K, V, R]       // hash map in region R
String[R]          // owned string in region R
Box[T, R]          // single-value box in region R
```

`R` is a compile-time identity, not a runtime pointer. `Vec[i64, arena_a]` and `Vec[i64, arena_b]` are different types; you cannot accidentally move data between them without an explicit copy.

The default region is the enclosing scope's arena, so most code never names `R`:

```q64
fn process(env: Env, items: [Order]): Report {
    let buf = Vec[u8]::new()       // R defaults to scope arena
    // ... write into buf, freed when scope exits
}
```

Explicit region passing is the Zig-pattern escape hatch for libraries that want allocator flexibility:

```q64
fn build_index[R: Region](r: R, terms: [Term]): Index[R] {
    let idx = Index::new(r)
    for t in terms { idx.insert(r, t) }
    idx
}
```

## Cross-region transfers

Values from one region don't silently move to another. The type system catches the mistake; named operations perform the explicit copy:

```q64
let a: Vec[u8, arena1] = ...
let b: Vec[u8, arena2] = a.copy_to(arena2)         // explicit deep copy
let c: Vec[u8, managed] = a.pin_to(managed_heap)   // copy to GC heap
let s: String[managed]  = "hello".intern()         // static -> managed, interned
```

Cross-heap transfers (linear ↔ managed) are *always* explicit and *always* involve a copy. There is no way in safe q64 to hold a linear pointer to managed data or a managed reference into linear memory.

## Lifetime tracking

Linear regions have explicit lifetimes; the compiler checks that values don't outlive their region. Rules:

- A region's lifetime is tied to the lexical scope or explicit lifetime that created it.
- A value's lifetime is bounded by its region's lifetime.
- A function cannot return a value allocated in one of its *local* regions.
- A function *can* return a value if the caller supplied the region.

The Zig-style "pass an allocator into anything that allocates" pattern makes returning safe — the caller's region is in scope, so returned values live in caller-owned memory:

```q64
fn parse[R: Region](r: R, input: str): Tree[R] {
    // Tree allocated in caller's region, safe to return
}
```

Managed types have no manual lifetime — the GC handles it. They are not constrained by scope boundaries. But they cannot escape their Wasm instance (their thread).

## Multi-memory architecture

Wasm 3.0's multiple-memory feature lets q64 segregate region kinds into distinct Wasm linear memory instances:

| Memory          | Purpose                                                |
|-----------------|--------------------------------------------------------|
| `mem.stack`     | Task stacks, one growable region per virtual thread    |
| `mem.arena`     | Per-scope bump arenas                                  |
| `mem.heap`      | Per-task free-list and pool regions                    |
| `mem.shared`    | Shared regions (SAB-backed in browser)                 |
| `mem.large`     | Allocations > some threshold (e.g. 1 MB) — fragmentation isolation |
| `mem.rodata`    | Static string and table data, marked read-only         |

Benefits:

- **Failure isolation**: a stack overflow doesn't corrupt arenas; a free-list bug doesn't taint shared data.
- **Protection**: read-only memory can be marked read-only at the host level (Wasm enforces it).
- **Sharing cost**: only `mem.shared` is SAB-backed. Thread-local memories don't pay the SAB overhead.
- **Diagnostics**: stack traces, heap dumps, and allocator reports name the originating memory.

User code never names a memory directly — it allocates from a region; the region knows which memory backs it. The multi-memory layout is a compiler/runtime concern, surfaced only in `q64 show` introspection.

## Concurrency interplay

The concurrency model and the memory model meet at three points.

### 1. `@send` is derived from memory composition

A type is `@send` if its ownership can transfer across a thread boundary safely. The compiler derives `@send` automatically from memory layout:

- Plain-value types (numbers, bools, structs of these) are `@send`.
- Linear types in a single-owner region are `@send`.
- Linear types in a shared region are `@send` (already shareable).
- Types containing managed references are **not** `@send` — GC roots are per-Wasm-instance.
- Types containing region pointers from a thread-local region are **not** `@send`.

Mixing a managed field into an otherwise-linear struct makes the whole struct non-`@send`, with the error pointing at the offending field.

### 2. Channels handle the heap boundary

- `Channel[T]` where `T: @send` and `T` is linear: SAB ring buffer transport. Zero-copy for fixed-layout values; copy through the ring for variable-sized.
- `Channel[T]` where `T` contains managed references: **serializing**. The compiler inserts copy-into-linear on send and reconstruct-managed on receive. Slower, and disqualifies the channel from `@realtime`.
- `Channel[Shared[T]]`: just clones the handle; the shared data already lives in `mem.shared`.

The cost difference is visible in the type. A `@realtime` audio stage cannot use a serializing channel because the copy is unbounded; the compiler rejects the graph.

### 3. Per-thread GC, shared linear

The WasmGC heap is per-Wasm-instance, which means per-Worker in the browser. A managed value cannot leave its thread without serialization.

Linear regions can be marked shared (`shared_region`); they live in `mem.shared` and use atomic operations or locks for synchronization. Tasks on any thread can access them.

This asymmetry is fundamental, not a current limitation. Managed memory exists *because* the engine collects it, and engine collectors operate within one Wasm instance.

## `Shared[T]` and synchronization

`Shared[T]` wraps a value with its synchronization protocol. Policies:

```q64
Shared[T, Mutex]          // exclusive access, blocking
Shared[T, RwLock]         // many readers or one writer
Shared[T, LockFree]       // requires T: Atomic or T: ImmutableSnapshot
Shared[T, Disjoint[F]]    // compile-time-verified disjoint field access
```

`atomic[T]` is the primitive for shared scalars — `atomic[i64]`, `atomic[bool]`, `atomic[Ptr[T]]`. Backed by Wasm 3.0 atomic ops (which include i64 atomics — relevant since q64's pointers are i64). Use directly when one variable is all you need; lift to `Shared[T, Mutex]` for aggregate state.

Most user code reaches for `Shared[T, Mutex]` or `atomic[T]`. The lock-free and disjoint variants are advanced, used for hot paths where the type system can prove safety without runtime checks.

## Allocator parameters as cultural pattern

Zig's influence, generalized to regions: anything that allocates takes the region as an explicit parameter.

```q64
fn intern[R: Region](r: R, s: str): String[R]
fn merge_sort[R: Region](r: R, items: [T]): Vec[T, R]
fn collect[R: Region, T](r: R, stream: Stream[T]): Vec[T, R]
```

This makes allocation visible at the call site, lets the caller pick the region kind (arena for fast/throwaway, managed for long-lived, pool for fixed-size), and keeps stdlib code generic over allocation strategy.

The exception: code that allocates in a known-scope-local way doesn't need to thread the region through — the scope's default arena is in scope already. So the boilerplate appears in libraries (where flexibility matters), not in application code (where the scope arena is the obvious answer).

## Diagnostics

Memory introspection is a first-class part of `q64 show`:

- `q64 show regions <fn>` — what regions a function uses or borrows from.
- `q64 show alloc <fn>` — allocation profile by region kind.
- `q64 show send <type>` — explain `@send`-ness, or the field that blocks it.
- `q64 show layout <type>` — memory layout, including which Wasm memory backs it.
- `q64 show memories` — which Wasm memories the program declares and their sizes.

Runtime stats — bytes per region, peak usage, fragmentation in free-list regions — are available through region handles for explicit querying. There is no single global allocator metric; everything is attributed to a region, which is attributed to a Wasm memory.

## Net

The memory model is shaped by what Wasm 3.0 in 64-bit mode makes cheap — Memory64, multiple memories, WasmGC, stack-switching, atomics — and by what the concurrency model requires: per-thread GC arenas, shareable linear, derived `@send`. The dual-heap design isn't a compromise; it's what the platform gives us, surfaced as first-class concepts rather than hidden behind a runtime.
