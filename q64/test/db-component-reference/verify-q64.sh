#!/usr/bin/env bash
# End-to-end check of the REAL `q64 emit --component` env.db lowering. Builds
# the db-scalar example through the q64 binary, validates the component, asserts
# it imports the q64-owned q64:db/sql interface + exports setup/add/count/namelen/
# firstrow, and — when jco + node:sqlite are available — transpiles it and runs
# CREATE/INSERT/COUNT/text/query_one against a real in-memory SQLite via a generic
# q64:db JS host (`host.mjs`), proving the canonical-ABI glue at runtime (in
# particular query_value's 8-aligned result<option<s64>,error> layout and
# query_one's zero-copy result<option<list<s64>>,error> row), not just structurally.
#
# env.db targets a q64-owned interface (exec + scalar query projections), NOT
# raw wasi:sql, whose single-cell row model + 13-case value variant + missing
# batch don't map to a landed q64 decode. See examples/db-scalar/db.q +
# src/codegen/wit/q64-db.wit.
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

echo "1. q64 emit --component on examples/db-scalar"
"$Q64" emit --component --addr wasm32 "$repo/examples/db-scalar/db.q" "$work/dbout.wasm"

echo "2. validate the emitted component"
"$WT" validate --features all "$work/dbout.component.wasm"

echo "3. assert it imports q64:db/sql + exports setup/add/count/namelen"
wit="$("$WT" component wit "$work/dbout.component.wasm")"
for needle in \
  "import q64:db/sql@0.2.0-draft2;" \
  "export setup: func() -> s64;" \
  "export add: func() -> s64;" \
  "export count: func() -> s64;" \
  "export namelen: func() -> s64;" \
  "export firstrow: func() -> s64;"; do
  grep -qF "$needle" <<<"$wit" || { echo "FAIL: missing $needle" >&2; exit 1; }
done

# Runtime proof (best effort): jco transpile + run on a real SQLite q64:db host.
if command -v node >/dev/null 2>&1 && npx -y @bytecodealliance/jco@latest --version >/dev/null 2>&1; then
  echo "4. runtime: jco transpile + run on a real SQLite q64:db/sql host"
  ( cd "$work" && npx -y @bytecodealliance/jco@latest transpile dbout.component.wasm -o jcoout --instantiation async >/dev/null )
  node "$here/host.mjs" "$work/jcoout"
else
  echo "4. runtime: SKIPPED (node/jco unavailable — structural checks above still passed)"
fi

echo "OK — q64 emits a working q64:db component for env.db."
