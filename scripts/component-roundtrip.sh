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
QUBE_BIN="$REPO_ROOT/qube/zig-out/bin/qube"
CHECK_BIN="$REPO_ROOT/runtime/wasmtime/zig-out/bin/q64-component-check"
WASMTOOLS_BIN="$REPO_ROOT/vendor/wasm-tools/wasm-tools"
# The WASIp3-capable component runner. The embedded wasmtime C API only does
# WASIp2; the CLI runs an app component under the async WASIp3 runtime (-S p3).
WASMTIME_BIN="$REPO_ROOT/vendor/wasmtime/bin/wasmtime"

export LD_LIBRARY_PATH="$REPO_ROOT/vendor/wasmtime/lib:${LD_LIBRARY_PATH:-}"
# The app path shells out to wasm-tools + the WASI preview1 adapter to lift the
# preview1 core into a `wasi:cli/run` command. Point q64 at the vendored
# toolchain explicitly so the lift works regardless of cwd.
export Q64_WASM_TOOLS="$WASMTOOLS_BIN"
export Q64_WASI_ADAPTER="$REPO_ROOT/vendor/wasi/wasi_snapshot_preview1.command.wasm"

if [[ ! -x "$ZIG" ]]; then
    echo "error: pinned zig not found at $ZIG — run ./init.sh first" >&2
    exit 2
fi

echo "==> building q64"
"$ZIG" build --build-file "$REPO_ROOT/q64/build.zig"
echo "==> building qube"
"$ZIG" build --build-file "$REPO_ROOT/qube/build.zig"
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

# --- app: lower env.out → WASI preview1, adapt, + run the real WASI command --
cat > "$tmp/app.q" <<'EOF'
fn main { env.out("Hello, q64.") }
EOF
echo "==> q64 emit --component (app, wasm32) lowers env.out → wasi_snapshot_preview1.fd_write, then wasm-tools --adapt"
"$Q64_BIN" emit "$tmp/app.q" "$tmp/app.wasm" --addr wasm32 --component
test -f "$tmp/app.component.wasm" || { echo "FAIL: no app component artifact" >&2; exit 1; }
echo "==> wasmtime: validate the app component"
"$CHECK_BIN" "$tmp/app.component.wasm"

# The component is produced by the reference tool (wasm-tools component new
# --adapt), so the assertion is that its world is the real WASI command world:
# it imports wasi:cli/stdout and exports wasi:cli/run. The CLI command world is
# wasi:cli@0.2.x (there is no wasi:cli@0.3 upstream — "WASIp3" is the async
# wasi:io layer, exercised at run time below via `-S p3`).
if [ -x "$WASMTOOLS_BIN" ]; then
    echo "==> wasm-tools: validate + extract the component's WIT (WASI command world)"
    "$WASMTOOLS_BIN" validate --features all "$tmp/app.component.wasm"
    wit="$("$WASMTOOLS_BIN" component wit "$tmp/app.component.wasm")"
    echo "$wit" | grep -q "import wasi:cli/stdout" || { echo "FAIL: WIT missing the wasi:cli/stdout import" >&2; echo "$wit" >&2; exit 1; }
    echo "$wit" | grep -q "export wasi:cli/run"   || { echo "FAIL: WIT missing the wasi:cli/run export" >&2; echo "$wit" >&2; exit 1; }
    echo "    ok: wasm-tools agrees — world imports wasi:cli/stdout, exports wasi:cli/run"
fi

# q64's synthesized world (show world) must name the same WASI interfaces.
echo "==> q64 show world names the WASI world (wasi:cli/stdout + wasi:cli/run)"
world="$("$Q64_BIN" show world --qube "$tmp/app.q")"
echo "$world" | grep -q "import wasi:cli/stdout" || { echo "FAIL: show world missing wasi:cli/stdout import" >&2; echo "$world" >&2; exit 1; }
echo "$world" | grep -q "export wasi:cli/run"   || { echo "FAIL: show world missing wasi:cli/run export" >&2; echo "$world" >&2; exit 1; }
echo "    ok: show world matches — import wasi:cli/stdout; export wasi:cli/run"

# Run the command under the WASIp3 (async) runtime — the wasmtime CLI's `-S p3`.
# The embedded C API only implements WASIp2, so the CLI is the p3-capable runner.
if [ -x "$WASMTIME_BIN" ]; then
    echo "==> wasmtime run -S p3: execute the app under the WASIp3 runtime"
    got="$("$WASMTIME_BIN" run -S p3 "$tmp/app.component.wasm")"
    if [ "$got" != "Hello, q64." ]; then
        echo "FAIL: app component printed '$got', expected 'Hello, q64.'" >&2
        exit 1
    fi
    echo "    ok: app component ran under -S p3 -> $got"
else
    echo "==> SKIP run: no vendored wasmtime CLI (run ./init.sh to fetch the WASIp3 runner)"
fi

# --- boundary: a wasm64 app import is not yet lowerable ----------------------
echo "==> q64 emit --component on a wasm64 app must error (no 64-bit canonical ABI yet)"
if "$Q64_BIN" emit "$tmp/app.q" "$tmp/app64.wasm" --addr wasm64 --component 2>/dev/null; then
    echo "FAIL: wasm64 app component unexpectedly succeeded" >&2
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

# --- qube build --component drives the same lift through the package tool -----
echo "==> qube build --component (examples/math-lib library)"
mathlib_dir="$REPO_ROOT/examples/math-lib"
rm -rf "$mathlib_dir/target"
( cd "$mathlib_dir" && Q64_BIN="$Q64_BIN" "$QUBE_BIN" build --component )
mathlib_comp="$mathlib_dir/target/debug/wasm64/dev.q64.math.component.wasm"
test -f "$mathlib_comp" || { echo "FAIL: qube build produced no component" >&2; exit 1; }
echo "==> wasmtime: call dev.q64.math add(40,2) == 42"
"$CHECK_BIN" "$mathlib_comp" add 40 2 42
rm -rf "$mathlib_dir/target"

echo "PASS: component lift validated by wasmtime (add/mul/sub), via q64 emit and qube build"
