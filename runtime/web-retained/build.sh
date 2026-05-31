#!/usr/bin/env bash
# Compile the retained reference screen to wasm32 and (optionally) serve it.
#   ./build.sh           # compile screen.q -> screen.wasm
#   ./build.sh --serve   # compile, then serve on :8787 (needs python3)
set -euo pipefail
cd "$(dirname "$0")"
Q64="../../q64/zig-out/bin/q64"
[ -x "$Q64" ] || { echo "build.sh: q64 not built — run: (cd ../../ && zig build --build-file q64/build.zig -Doptimize=ReleaseSafe)"; exit 1; }
"$Q64" emit screen.q screen.wasm --addr wasm32
echo "build.sh: screen.wasm ($(wc -c <screen.wasm) bytes)"
if [ "${1:-}" = "--serve" ]; then
  echo "build.sh: serving http://localhost:8787 (Ctrl-C to stop)"
  exec python3 -m http.server 8787
fi
