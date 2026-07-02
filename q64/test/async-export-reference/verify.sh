#!/usr/bin/env bash
# Reference for futures Slice B rung 3 — the ASYNC-LIFTED component export
# (Component Model async ABI: callback re-entry + task.return). Two
# hand-authored cores pin the protocol before codegen learns it:
#
#   yield-core.wat      — no host imports: initial call returns YIELD, the
#                         host re-enters the callback, task.return delivers.
#                         Proves lift/callback/task.return in isolation.
#   reference-core.wat  — the real thing: nap(ns) starts wait-for(ns) as an
#                         async-lowered SUBTASK, joins it to a waitable-set,
#                         returns WAIT(set); the callback fires on subtask
#                         completion and task.returns the measured span. The
#                         host thread never blocks.
#
# See README.md for the constants and the scheduler↔callback codegen mapping.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
WT="${Q64_WASM_TOOLS:-$repo/vendor/wasm-tools/wasm-tools}"
WASMTIME="${Q64_WASMTIME:-$repo/vendor/wasmtime/bin/wasmtime}"

if [[ ! -x "$WASMTIME" ]]; then
  echo "verify.sh: wasmtime CLI not found at $WASMTIME — vendor it (or set Q64_WASMTIME)" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

build() { # $1 = wat, $2 = out component
  "$WT" parse "$here/$1" -o "$work/core.wasm"
  "$WT" component embed "$here/wit" --world qube "$work/core.wasm" -o "$work/embed.wasm"
  "$WT" component new "$work/embed.wasm" -o "$2"
  "$WT" validate --features all "$2"
}

echo "1. yield-core: async lift + callback re-entry + task.return (no imports)"
# The yield core has no clock import; embed it against a world without the
# import by stripping the import line into a temp wit.
mkdir -p "$work/wit1"
sed '/import wasi:clocks/d' "$here/wit/world.wit" > "$work/wit1/world.wit"
"$WT" parse "$here/yield-core.wat" -o "$work/core1.wasm"
"$WT" component embed "$work/wit1" --world qube "$work/core1.wasm" -o "$work/embed1.wasm"
"$WT" component new "$work/embed1.wasm" -o "$work/yield.component.wasm"
got="$("$WASMTIME" run -W component-model-async -S p3 --invoke 'nap(41)' "$work/yield.component.wasm")"
[[ "$got" == "42" ]] || { echo "FAIL: yield nap(41) = $got, expected 42" >&2; exit 1; }
echo "   nap(41) -> $got (host re-entered the callback ✓)"

echo "2. reference-core: async wait-for subtask + waitable-set + WAIT + callback"
build reference-core.wat "$work/nap.component.wasm"
span="$("$WASMTIME" run -W component-model-async -S p3 --invoke 'nap(250000000)' "$work/nap.component.wasm")"
# The measured span must be >= the requested 250ms and sane (< 5s).
[[ "$span" -ge 250000000 && "$span" -lt 5000000000 ]] || {
  echo "FAIL: nap(250ms) measured $span ns" >&2; exit 1; }
echo "   nap(250ms) -> measured $span ns, delivered via task.return ✓"

echo "3. q64 codegen: a suspending pub fn compiles to the same protocol"
Q64="${Q64_BIN:-$repo/q64/zig-out/bin/q64}"
if [[ -x "$Q64" ]]; then
  cat > "$work/nap.q" <<'EOF'
pub fn nap(ns: i64) -> i64 {
    let t0 = env.time.monotonic_ns()
    env.time.sleep_ns(ns)
    env.time.monotonic_ns() - t0
}
EOF
  Q64_WASM_TOOLS="$WT" "$Q64" emit "$work/nap.q" "$work/qnap.wasm" --addr wasm32 --component
  qspan="$("$WASMTIME" run -W component-model-async -S p3 --invoke 'nap(200000000)' "$work/qnap.component.wasm")"
  [[ "$qspan" -ge 200000000 && "$qspan" -lt 5000000000 ]] || {
    echo "FAIL: q64-compiled nap(200ms) measured $qspan ns" >&2; exit 1; }
  echo "   q64 nap(200ms) -> measured $qspan ns via the async lift ✓"
else
  echo "   SKIPPED (q64 not built at $Q64)"
fi

echo "OK — the async-lifted export protocol round-trips under wasmtime -S p3."
