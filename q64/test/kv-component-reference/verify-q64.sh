#!/usr/bin/env bash
# End-to-end check of the REAL `q64 emit --component` env.kv lowering (vs.
# `run.sh`, which exercises the hand-written reference core). Builds the
# kv-counter example through the q64 binary, validates the component, and — when
# jco + a network are available — transpiles it and runs `bump`/`read` against a
# generic wasi:keyvalue JS host (`host.mjs`), proving the canonical-ABI glue at
# runtime, not just structurally.
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

echo "1. q64 emit --component on examples/kv-counter"
"$Q64" emit --component --addr wasm32 "$repo/examples/kv-counter/kv.q" "$work/kvout.wasm"

echo "2. validate the emitted component"
"$WT" validate --features all "$work/kvout.component.wasm"

echo "3. assert it imports real wasi:keyvalue + exports bump/read"
wit="$("$WT" component wit "$work/kvout.component.wasm")"
for needle in \
  "import wasi:keyvalue/store@0.2.0-draft2;" \
  "import wasi:keyvalue/atomics@0.2.0-draft2;" \
  "export bump: func() -> s64;" \
  "export read: func() -> s64;"; do
  grep -qF "$needle" <<<"$wit" || { echo "FAIL: missing $needle" >&2; exit 1; }
done

# Runtime proof (best effort): jco transpile + run on a generic wasi:keyvalue host.
if command -v node >/dev/null 2>&1 && npx -y @bytecodealliance/jco@latest --version >/dev/null 2>&1; then
  echo "4. runtime: jco transpile + run on a generic wasi:keyvalue host"
  ( cd "$work" && npx -y @bytecodealliance/jco@latest transpile kvout.component.wasm -o jcoout --instantiation async >/dev/null )
  node "$here/host.mjs" "$work/jcoout"
else
  echo "4. runtime: SKIPPED (node/jco unavailable — structural checks above still passed)"
fi

echo "OK — q64 emits a working wasi:keyvalue component for env.kv."
