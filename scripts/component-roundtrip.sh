#!/usr/bin/env bash
# scripts/component-roundtrip.sh
#
# End-to-end smoke test for component emission (todo.md "component/WIT lift"):
#
#   a scalar library (pub fn add / mul)
#     -> q64 emit --component   (core module + <name>.component.wasm)
#     -> q64-component-check     (wasmtime: validate + call the lifted exports)
#     -> add(2,3)==5, mul(6,7)==42
#
# Proves `q64 emit --component` produces a real WebAssembly component that
# wasmtime accepts and can instantiate + call through the canonical ABI.
# Also checks the honest boundaries: a qube that imports a capability face
# (env.out) is rejected (import lowering not yet implemented), and a non-scalar
# (str) export is skipped rather than mis-lifted.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ZIG="$REPO_ROOT/vendor/zig/zig"
Q64_BIN="$REPO_ROOT/q64/zig-out/bin/q64"
CHECK_BIN="$REPO_ROOT/runtime/wasmtime/zig-out/bin/q64-component-check"

export LD_LIBRARY_PATH="$REPO_ROOT/vendor/wasmtime/lib:${LD_LIBRARY_PATH:-}"

if [[ ! -x "$ZIG" ]]; then
    echo "error: pinned zig not found at $ZIG — run ./init.sh first" >&2
    exit 2
fi

echo "==> building q64"
"$ZIG" build --build-file "$REPO_ROOT/q64/build.zig"
echo "==> building component validator (wasmtime)"
"$ZIG" build --build-file "$REPO_ROOT/runtime/wasmtime/build.zig"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- scalar library: lift + validate + call ---------------------------------
cat > "$tmp/mathlib.q" <<'EOF'
pub fn add(a: i64, b: i64) -> i64 { a + b }
pub fn mul(a: i64, b: i64) -> i64 { a * b }
EOF

echo "==> q64 emit --component (scalar library)"
"$Q64_BIN" emit "$tmp/mathlib.q" "$tmp/mathlib.wasm" --addr wasm32 --component
test -f "$tmp/mathlib.component.wasm" || { echo "FAIL: no component artifact" >&2; exit 1; }

echo "==> wasmtime: validate component"
"$CHECK_BIN" "$tmp/mathlib.component.wasm"
echo "==> wasmtime: call add(2,3) == 5"
"$CHECK_BIN" "$tmp/mathlib.component.wasm" add 2 3 5
echo "==> wasmtime: call mul(6,7) == 42"
"$CHECK_BIN" "$tmp/mathlib.component.wasm" mul 6 7 42

# --- boundary: a capability import is rejected, not mis-wrapped --------------
cat > "$tmp/app.q" <<'EOF'
fn main { env.out("hi") }
EOF
echo "==> q64 emit --component on an app that writes stdout must error"
if "$Q64_BIN" emit "$tmp/app.q" "$tmp/app.wasm" --addr wasm32 --component 2>/dev/null; then
    echo "FAIL: component emit on a capability-importing qube unexpectedly succeeded" >&2
    exit 1
fi

# --- boundary: a non-scalar (str) export is skipped, scalars still lift ------
cat > "$tmp/mixed.q" <<'EOF'
pub fn version() -> str { "0.1.0" }
pub fn sub(a: i64, b: i64) -> i64 { a - b }
EOF
echo "==> q64 emit --component (mixed str + scalar) lifts the scalar export"
"$Q64_BIN" emit "$tmp/mixed.q" "$tmp/mixed.wasm" --addr wasm32 --component
"$CHECK_BIN" "$tmp/mixed.component.wasm" sub 50 8 42

echo "PASS: component lift validated by wasmtime (add/mul/sub), boundaries honest"
