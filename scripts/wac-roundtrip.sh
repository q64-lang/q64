#!/usr/bin/env bash
# scripts/wac-roundtrip.sh
#
# End-to-end smoke test for `qube wac` — the on-device component linker
# (link at build, qubepods TODO §"qube wac"):
#
#   a provider component (exports test:shared/math)
#   + a consumer component (imports test:shared/math, exports compute)
#     -> qube wac plug consumer --plug provider -o composed
#     -> wasm-tools validate: the import is SATISFIED (composed exports only
#        compute; the test:shared/math import is gone — wired internally)
#
# Engine: the real `wac` when available (env Q64_WAC or vendor/wac/wac), else
# the vendored `wasm-tools compose` fallback. Both are exercised when present.
#
# The provider/consumer are built with wasm-tools (q64 doesn't yet emit
# matching-interface-id exports — the source-level foreign-call work); this
# proves the `qube wac` plumbing + the composition engine.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ZIG="$REPO_ROOT/vendor/zig/zig"
QUBE_BIN="$REPO_ROOT/qube/zig-out/bin/qube"
WASMTOOLS_BIN="$REPO_ROOT/vendor/wasm-tools/wasm-tools"

if [[ ! -x "$WASMTOOLS_BIN" ]]; then
    echo "SKIP: wasm-tools not vendored (run ./init.sh)" >&2
    exit 0
fi

echo "==> building qube"
"$ZIG" build --build-file "$REPO_ROOT/qube/build.zig"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- provider: exports test:shared/math -------------------------------------
cat > "$tmp/p.wit" <<'EOF'
package test:shared;
interface math { add: func(a: s64, b: s64) -> s64; }
world provider { export math; }
EOF
cat > "$tmp/pc.wat" <<'EOF'
(module (func (export "test:shared/math#add") (param i64 i64) (result i64)
  (i64.add (local.get 0) (local.get 1))))
EOF
"$WASMTOOLS_BIN" parse "$tmp/pc.wat" -o "$tmp/pc.wasm"
"$WASMTOOLS_BIN" component embed "$tmp/p.wit" "$tmp/pc.wasm" --world provider -o "$tmp/pe.wasm"
"$WASMTOOLS_BIN" component new "$tmp/pe.wasm" -o "$tmp/provider.wasm"

# --- consumer: imports test:shared/math, exports compute --------------------
cat > "$tmp/c.wit" <<'EOF'
package test:shared;
interface math { add: func(a: s64, b: s64) -> s64; }
world consumer { import math; export compute: func() -> s64; }
EOF
cat > "$tmp/cc.wat" <<'EOF'
(module
  (import "test:shared/math" "add" (func $add (param i64 i64) (result i64)))
  (func (export "compute") (result i64) (call $add (i64.const 40) (i64.const 2))))
EOF
"$WASMTOOLS_BIN" parse "$tmp/cc.wat" -o "$tmp/cc.wasm"
"$WASMTOOLS_BIN" component embed "$tmp/c.wit" "$tmp/cc.wasm" --world consumer -o "$tmp/ce.wasm"
"$WASMTOOLS_BIN" component new "$tmp/ce.wasm" -o "$tmp/consumer.wasm"

# The consumer alone imports test:shared/math (unsatisfied).
"$WASMTOOLS_BIN" component wit "$tmp/consumer.wasm" | grep -q "import test:shared/math" \
    || { echo "FAIL: consumer should import test:shared/math" >&2; exit 1; }

assert_composed() {
    local out="$1" label="$2"
    "$WASMTOOLS_BIN" validate "$out" >/dev/null || { echo "FAIL ($label): composed component invalid" >&2; exit 1; }
    local wit; wit="$("$WASMTOOLS_BIN" component wit "$out")"
    echo "$wit" | grep -q "export compute: func() -> s64" || { echo "FAIL ($label): composed missing export compute" >&2; echo "$wit" >&2; exit 1; }
    echo "$wit" | grep -q "import test:shared/math" && { echo "FAIL ($label): import NOT satisfied (still present)" >&2; echo "$wit" >&2; exit 1; }
    echo "    ok ($label): composed validates, export compute kept, test:shared/math import satisfied"
}

# --- fallback engine: wasm-tools compose (always available) ------------------
# Clear Q64_WAC so the fallback is genuinely exercised even if a wac is on hand.
echo "==> qube wac plug (wasm-tools compose fallback)"
env -u Q64_WAC Q64_WASM_TOOLS="$WASMTOOLS_BIN" "$QUBE_BIN" wac plug "$tmp/consumer.wasm" --plug "$tmp/provider.wasm" -o "$tmp/out-wt.wasm" \
    2>&1 | grep -v "deprecated\|wac instead\|information about" || true
assert_composed "$tmp/out-wt.wasm" "wasm-tools compose"

# --- real wac, if available -------------------------------------------------
WAC_BIN="${Q64_WAC:-$REPO_ROOT/vendor/wac/wac}"
if [[ -x "$WAC_BIN" ]]; then
    echo "==> qube wac plug (real wac: $WAC_BIN)"
    Q64_WAC="$WAC_BIN" "$QUBE_BIN" wac plug "$tmp/consumer.wasm" --plug "$tmp/provider.wasm" -o "$tmp/out-wac.wasm"
    assert_composed "$tmp/out-wac.wasm" "wac plug"
else
    echo "==> SKIP real wac (set Q64_WAC or vendor vendor/wac/wac to exercise it)"
fi

echo "PASS: qube wac links a consumer + provider into one component (import satisfied)"
