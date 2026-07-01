#!/usr/bin/env bash
# End-to-end check of the REAL `q64 emit --component` env.blob lowering. Builds
# the blob-store example through the q64 binary, validates the component,
# asserts it imports the q64-owned q64:blob/store interface + exports
# save/read/drop, and — when jco + a network are available — transpiles it and
# runs a put/get/delete round-trip against a generic q64:blob JS host
# (`host.mjs`), proving the canonical-ABI glue at runtime, not just structurally.
#
# env.blob targets a q64-owned interface (flat list<u8>), NOT raw
# wasi:blobstore, whose write path is stream-only (wasi:io) and not yet emitted
# by q64 codegen. See examples/blob-store/blob.q + src/codegen/wit/q64-blob.wit.
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

echo "1. q64 emit --component on examples/blob-store"
"$Q64" emit --component --addr wasm32 "$repo/examples/blob-store/blob.q" "$work/blobout.wasm"

echo "2. validate the emitted component"
"$WT" validate --features all "$work/blobout.component.wasm"

echo "3. assert it imports q64:blob/store + exports save/read/drop"
wit="$("$WT" component wit "$work/blobout.component.wasm")"
for needle in \
  "import q64:blob/store@0.2.0-draft2;" \
  "export save: func() -> s64;" \
  "export read: func() -> s64;" \
  "export drop: func() -> s64;"; do
  grep -qF "$needle" <<<"$wit" || { echo "FAIL: missing $needle" >&2; exit 1; }
done

# Runtime proof (best effort): jco transpile + run on a generic q64:blob host.
if command -v node >/dev/null 2>&1 && npx -y @bytecodealliance/jco@latest --version >/dev/null 2>&1; then
  echo "4. runtime: jco transpile + run on a generic q64:blob host"
  ( cd "$work" && npx -y @bytecodealliance/jco@latest transpile blobout.component.wasm -o jcoout --instantiation async >/dev/null )
  node "$here/host.mjs" "$work/jcoout"
else
  echo "4. runtime: SKIPPED (node/jco unavailable — structural checks above still passed)"
fi

echo "OK — q64 emits a working q64:blob component for env.blob."
