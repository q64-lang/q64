#!/usr/bin/env bash
# End-to-end check of the REAL `q64 emit --component` @http_handler lowering (a
# str-in / str-out component EXPORT via the canonical-ABI return-area wrapper).
# Builds the http-handler example through the q64 binary, validates the
# component, asserts it exports `serve: func(method, path, body: string) ->
# string`, and — when jco + a network are available — transpiles it and calls
# the handler with a request, checking the response string.
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

echo "1. q64 emit --component on examples/http-handler"
"$Q64" emit --component --addr wasm32 "$repo/examples/http-handler/http.q" "$work/httpout.wasm"

echo "2. validate the emitted component"
"$WT" validate --features all "$work/httpout.component.wasm"

echo "3. assert it exports the str-in/str-out handler"
wit="$("$WT" component wit "$work/httpout.component.wasm")"
grep -qF "export serve: func(method: string, path: string, body: string) -> string;" <<<"$wit" \
  || { echo "FAIL: missing the serve export" >&2; exit 1; }

# Runtime proof (best effort): jco transpile + call the handler.
if command -v node >/dev/null 2>&1 && npx -y @bytecodealliance/jco@latest --version >/dev/null 2>&1; then
  echo "4. runtime: jco transpile + call the handler with a request"
  ( cd "$work" && npx -y @bytecodealliance/jco@latest transpile httpout.component.wasm -o jcoout --instantiation async >/dev/null )
  node "$here/host.mjs" "$work/jcoout"
else
  echo "4. runtime: SKIPPED (node/jco unavailable — structural checks above still passed)"
fi

echo "OK — q64 emits a working @http_handler component (str-in/str-out export)."
