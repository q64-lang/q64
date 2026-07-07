# Crypto directions — wide integers and constant-time execution

Status: design note (2026-07), per `docs/language-analysis-2026-07.md` §4
(crypto). Records the two language-level deltas; everything else in the
crypto story (deterministic Wasm, capability sandboxing, metering) q64
already has or hosts already provide.

## Wide integers

- `i128`/`u128` already exist in the sema TypeStore tower; the gap is
  codegen (a pair-of-i64 lowering, the same shape every 64-bit target
  uses). This is the "one rung" item.
- `u256` — the contract-chain word size — should be a **stdlib type over
  `u128` limbs** (`q64.bigint`, fixed-width, no allocation), not a
  compiler builtin: nothing below the stdlib needs it, and the operator
  faces make it ergonomic (`a + b` via `fit U256 : Add`).

## `@const_time` — a checked assert, not a hope

The novel piece: no production language enforces constant-time at the
type level, and q64's effect-assert machinery is exactly the right home.

- `@const_time` joins the assert family (`@no_alloc`-style, propagates
  down). A `@const_time` function rejects, at compile time on MIR:
  branches whose condition is secret-derived, memory accesses whose
  address is secret-derived, and calls to non-`@const_time` functions.
- "Secret-derived" needs a taint source: a **`Secret<T>` kind** (the
  `@kind` newtype machinery) marking key material; taint propagates
  through dataflow on MIR, cleared only by an explicit `declassify()`.
- v0 scope: straight-line integer/bitwise code (exactly what real
  constant-time primitives are); the checker is a MIR walk, not a solver.
- Verified primitives (HACL*, libsodium) arrive via the wasm FFI path and
  are *declared* `@const_time` at the boundary — the assert then protects
  the q64 glue around them, which is where timing bugs actually creep in.

## What q64 already brings (no work needed)

Deterministic execution modulo capabilities (the contract-runtime
requirement — see `docs/deterministic-profile.md`), capability
sandboxing as the plugin/contract security model, Wasm as the
already-standard contract substrate (CosmWasm/NEAR/Stylus), and gas
metering as a host/Binaryen instrumentation pass, not a language change.

Sequencing: i128/u128 codegen → `q64.bigint` U256 → `Secret<T>` kind +
the `@const_time` MIR walk. A `qube deploy --target` for a contract chain
is a product decision that can ride any point after the first two.
