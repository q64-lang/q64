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
# Two layers: (1) a wasm-tools-built provider/consumer pair proves the `qube wac`
# plumbing + composition engine; (2) a q64↔q64 pair proves the real path — a q64
# provider exports a named interface, a q64 consumer makes a source-level foreign
# CALL (`math.add(x, 100)`) that lowers to a wired core import, they're linked,
# and the linked component is RUN to confirm the call reached the provider.

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

# Assert a q64↔q64 link: valid, exports `compute`, no `import` line survives.
assert_composed_iface() {
    local out="$1" label="$2"
    "$WASMTOOLS_BIN" validate "$out" >/dev/null || { echo "FAIL ($label): composed component invalid" >&2; exit 1; }
    local wit; wit="$("$WASMTOOLS_BIN" component wit "$out")"
    echo "$wit" | grep -qE "export compute:" || { echo "FAIL ($label): composed missing export compute" >&2; echo "$wit" >&2; exit 1; }
    echo "$wit" | grep -qE "^\s*import " && { echo "FAIL ($label): an import is unsatisfied" >&2; echo "$wit" >&2; exit 1; }
    echo "    ok ($label): two q64 components linked — exports compute, acme:mathlib/math import satisfied"
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

# --- q64 ↔ q64: two q64 qubes link (interface export + foreign import) --------
Q64_BIN="${Q64_BIN:-$REPO_ROOT/q64/zig-out/bin/q64}"
if [[ -x "$Q64_BIN" ]]; then
    echo "==> q64 ↔ q64: provider exports an interface, consumer imports it, qube wac links"
    export Q64_WASM_TOOLS="$WASMTOOLS_BIN"
    # Provider: a q64 library exporting the named interface acme:mathlib/math.
    printf 'pub fn add(a: i64, b: i64) -> i64 { a + b }\n' > "$tmp/qprov.q"
    "$Q64_BIN" emit "$tmp/qprov.q" "$tmp/qprov.wasm" --addr wasm32 --component --export-interface "acme:mathlib/math"
    "$WASMTOOLS_BIN" component wit "$tmp/qprov.component.wasm" | grep -q "export acme:mathlib/math" \
        || { echo "FAIL: q64 provider does not export the interface" >&2; exit 1; }
    # Consumer: a q64 library that imports acme:mathlib/math AND calls it —
    # `compute(x)` is `math.add(x, 100)`, a real source-level foreign call that
    # lowers to a core import the component wires to the imported interface.
    printf 'package acme:mathlib;\ninterface math { add: func(a: s64, b: s64) -> s64; }\n' > "$tmp/math.wit"
    printf 'pub fn compute(x: i64) -> i64 { math.add(x, 100) }\n' > "$tmp/qcons.q"
    "$Q64_BIN" emit "$tmp/qcons.q" "$tmp/qcons.wasm" --addr wasm32 --component --wit-import "$tmp/math.wit"
    "$WASMTOOLS_BIN" component wit "$tmp/qcons.component.wasm" | grep -q "import acme:mathlib/math" \
        || { echo "FAIL: q64 consumer does not import the interface" >&2; exit 1; }
    # The consumer alone is a valid component whose core genuinely imports the
    # foreign func (not a phantom forward-declaration).
    "$WASMTOOLS_BIN" validate "$tmp/qcons.component.wasm" \
        || { echo "FAIL: q64 consumer component invalid" >&2; exit 1; }
    "$QUBE_BIN" wac plug "$tmp/qcons.component.wasm" --plug "$tmp/qprov.component.wasm" -o "$tmp/qlinked.wasm" \
        2>&1 | grep -v "deprecated\|wac instead\|information about" || true
    assert_composed_iface "$tmp/qlinked.wasm" "q64↔q64"

    # Run the linked component: `compute(x)` must invoke the provider's `add`
    # across the component boundary, so `compute(5)` == add(5, 100) == 105. This
    # is the end-to-end proof the foreign CALL works, not just the wiring.
    WASMTIME_BIN="${Q64_WASMTIME:-$REPO_ROOT/vendor/wasmtime/bin/wasmtime}"
    if [[ -x "$WASMTIME_BIN" ]]; then
        got="$("$WASMTIME_BIN" run --invoke 'compute(5)' "$tmp/qlinked.wasm" 2>/dev/null | tr -d '[:space:]')"
        [[ "$got" == "105" ]] \
            && echo "    ok (q64↔q64 run): compute(5) = 105 — the foreign call reached the linked provider" \
            || { echo "FAIL: linked compute(5) = '$got', expected 105" >&2; exit 1; }
    else
        echo "    SKIP run (set Q64_WASMTIME or vendor vendor/wasmtime/bin/wasmtime to execute the link)"
    fi
else
    echo "==> SKIP q64↔q64 (set Q64_BIN or build q64 to exercise it)"
fi

echo "PASS: qube wac links a consumer + provider into one component (import satisfied)"
