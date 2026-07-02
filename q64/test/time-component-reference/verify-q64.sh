#!/usr/bin/env bash
# End-to-end check of the REAL `q64 emit --component` env.time lowering. Builds
# the time-mono example through the q64 binary, validates the component, asserts
# it imports the stable wasi:clocks/monotonic-clock interface + exports
# mono/delta, and — when jco + a network are available — transpiles it and runs
# both against a generic monotonic-clock JS host (`host.mjs`), proving the
# bare-scalar canonical-ABI glue at runtime (a nullary top-level `now`).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"          # the q64/ binary dir (q64/)
repo="$(cd "$root/.." && pwd)"             # repo root
WT="${Q64_WASM_TOOLS:-$repo/vendor/wasm-tools/wasm-tools}"
Q64="${Q64_BIN:-$root/zig-out/bin/q64}"

if [[ ! -x "$Q64" ]]; then
  echo "verify-q64.sh: q64 not built at $Q64 — run 'zig build' in $root first" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "1. q64 emit --component on examples/time-mono"
"$Q64" emit --component --addr wasm32 "$repo/examples/time-mono/time.q" "$work/timeout.wasm"

echo "2. validate the emitted component"
"$WT" validate --features all "$work/timeout.component.wasm"

echo "3. assert it imports wasi:clocks/monotonic-clock + exports mono/delta"
wit="$("$WT" component wit "$work/timeout.component.wasm")"
for needle in \
  "import wasi:clocks/monotonic-clock@0.2.0;" \
  "export mono: func() -> s64;" \
  "export delta: func() -> s64;"; do
  grep -qF "$needle" <<<"$wit" || { echo "FAIL: missing $needle" >&2; exit 1; }
done

# Runtime proof (best effort): jco transpile + run on a generic clock host.
if command -v node >/dev/null 2>&1 && npx -y @bytecodealliance/jco@latest --version >/dev/null 2>&1; then
  echo "4. runtime: jco transpile + run on a generic wasi:clocks host"
  ( cd "$work" && npx -y @bytecodealliance/jco@latest transpile timeout.component.wasm -o jcoout --instantiation async >/dev/null )
  node "$here/host.mjs" "$work/jcoout"
else
  echo "4. runtime: SKIPPED (node/jco unavailable — structural checks above still passed)"
fi

echo "OK — q64 emits a working wasi:clocks component for env.time."
