#!/usr/bin/env bash
# End-to-end check of the REAL `q64 emit --component` env.config lowering. Builds
# the config-read example through the q64 binary, validates the component,
# asserts it imports the real wasi:config/store interface + exports read/missing,
# and — when jco + a network are available — transpiles it and runs a present /
# absent key read against a generic wasi:config/store JS host (`host.mjs`),
# proving the canonical-ABI glue at runtime (a handle-less top-level `get`).
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

echo "1. q64 emit --component on examples/config-read"
"$Q64" emit --component --addr wasm32 "$repo/examples/config-read/config.q" "$work/cfgout.wasm"

echo "2. validate the emitted component"
"$WT" validate --features all "$work/cfgout.component.wasm"

echo "3. assert it imports wasi:config/store + exports read/missing"
wit="$("$WT" component wit "$work/cfgout.component.wasm")"
for needle in \
  "import wasi:config/store@0.2.0-draft;" \
  "export read: func() -> s64;" \
  "export missing: func() -> s64;"; do
  grep -qF "$needle" <<<"$wit" || { echo "FAIL: missing $needle" >&2; exit 1; }
done

# Runtime proof (best effort): jco transpile + run on a generic wasi:config host.
if command -v node >/dev/null 2>&1 && npx -y @bytecodealliance/jco@latest --version >/dev/null 2>&1; then
  echo "4. runtime: jco transpile + run on a generic wasi:config/store host"
  ( cd "$work" && npx -y @bytecodealliance/jco@latest transpile cfgout.component.wasm -o jcoout --instantiation async >/dev/null )
  node "$here/host.mjs" "$work/jcoout"
else
  echo "4. runtime: SKIPPED (node/jco unavailable — structural checks above still passed)"
fi

echo "OK — q64 emits a working wasi:config component for env.config."
