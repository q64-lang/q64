#!/usr/bin/env bash
# Conformance reference for the `env.kv` → `wasi:keyvalue` component lowering.
#
# Builds the hand-written reference core (`reference-core.wat`) into a real
# component importing `wasi:keyvalue/{store,atomics}@0.2.0-draft2` and validates
# it. This is the design-of-record `q64 emit --component` targets: if q64's
# Binaryen codegen ever drifts from this shape, the lift breaks and this script
# is the oracle. No q64 build needed — it exercises wasm-tools directly.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
WT="${Q64_WASM_TOOLS:-$root/vendor/wasm-tools/wasm-tools}"

if [[ ! -x "$WT" ]]; then
  echo "run.sh: wasm-tools not found at $WT — run ./init.sh or set Q64_WASM_TOOLS" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/wit/deps/wasi-keyvalue"
cp "$here/wasi-keyvalue.wit" "$work/wit/deps/wasi-keyvalue/"
cp "$here/world.wit" "$work/wit/world.wit"

echo "1. assemble core (reference-core.wat → wasm)"
"$WT" parse "$here/reference-core.wat" -o "$work/core.wasm"

echo "2. embed the synthesized world + wasi:keyvalue dep"
"$WT" component embed "$work/wit" --world qube "$work/core.wasm" -o "$work/embed.wasm"

echo "3. lift core → component"
"$WT" component new "$work/embed.wasm" -o "$work/component.wasm"

echo "4. validate"
"$WT" validate --features all "$work/component.wasm"

echo "5. assert the component imports real wasi:keyvalue + exports bump"
wit="$("$WT" component wit "$work/component.wasm")"
for needle in \
  "import wasi:keyvalue/store@0.2.0-draft2;" \
  "import wasi:keyvalue/atomics@0.2.0-draft2;" \
  "export bump: func() -> s64;"; do
  if ! grep -qF "$needle" <<<"$wit"; then
    echo "FAIL: component WIT missing: $needle" >&2
    echo "$wit" >&2
    exit 1
  fi
done

echo "OK — env.kv lowers to a valid wasi:keyvalue component."
