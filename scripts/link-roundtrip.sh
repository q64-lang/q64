#!/usr/bin/env bash
# scripts/link-roundtrip.sh
#
# End-to-end smoke test for cross-qube linking (todo.md "linking ladder"):
#
#   examples/link-demo/hello_app/src/main.q
#     -> q64 emit --module dev.q64.hello_world=<lib>/src   (resolve + emit version())
#     -> app.wasm
#     -> q64-wasmtime-host                                  (runtime adapter)
#     -> stdout == "0.1.0"
#
# `version()` lives in the dependency dev.q64.hello_world; the app imports
# it and calls it directly (`env.out(version())`). codegen emits `version`
# as a real `() -> (i32, i32)` function and calls it at runtime — a real,
# non-const-folded cross-module call. Covers parse -> imports ->
# resolution -> callee emission -> string-return ABI -> codegen -> host.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ZIG="$REPO_ROOT/vendor/zig/zig"
Q64_BIN="$REPO_ROOT/q64/zig-out/bin/q64"
HOST_BIN="$REPO_ROOT/runtime/wasmtime/zig-out/bin/q64-wasmtime-host"
QUBE_BIN="$REPO_ROOT/qube/zig-out/bin/qube"

DEMO="$REPO_ROOT/examples/link-demo"
APP="$DEMO/hello_app/src/main.q"
APP_DIR="$DEMO/hello_app"
LIB_SRC="$DEMO/hello_world/src"

if [[ ! -x "$ZIG" ]]; then
    echo "error: pinned zig not found at $ZIG — run ./init.sh first" >&2
    exit 2
fi

echo "==> building q64"
"$ZIG" build --build-file "$REPO_ROOT/q64/build.zig"

echo "==> building wasmtime runtime adapter"
"$ZIG" build --build-file "$REPO_ROOT/runtime/wasmtime/build.zig"

echo "==> building qube"
"$ZIG" build --build-file "$REPO_ROOT/qube/build.zig"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
wasm="$tmp/app.wasm"

# Honest baseline: emitting without the dependency must fail, not embed
# the literal "{version()}".
echo "==> q64 emit (no --module) must error"
if "$Q64_BIN" emit "$APP" "$wasm" 2>/dev/null; then
    echo "FAIL: emit without --module unexpectedly succeeded" >&2
    exit 1
fi
echo "    ok: errored as expected"

echo "==> q64 emit --module dev.q64.hello_world=$LIB_SRC"
"$Q64_BIN" emit "$APP" "$wasm" --module "dev.q64.hello_world=$LIB_SRC"

if [[ ! -s "$wasm" ]]; then
    echo "FAIL: emit produced an empty file" >&2
    exit 1
fi

echo "==> $HOST_BIN $wasm"
actual="$("$HOST_BIN" "$wasm")"
expected="0.1.0"

if [[ "$actual" != "$expected" ]]; then
    echo "FAIL: output mismatch" >&2
    printf "  expected: %q\n" "$expected" >&2
    printf "  actual:   %q\n" "$actual" >&2
    exit 1
fi
echo "    ok: q64 emit --module -> $actual"

# Full path: `qube run` reads the JSON5 manifest, resolves the local-path
# dependency into a --module flag, emits, and runs the host itself.
echo "==> (cd hello_app && qube run)"
qube_out="$(cd "$APP_DIR" && Q64_BIN="$Q64_BIN" Q64_HOST="$HOST_BIN" "$QUBE_BIN" run)"
if [[ "$qube_out" != "$expected" ]]; then
    echo "FAIL: qube run output mismatch" >&2
    printf "  expected: %q\n" "$expected" >&2
    printf "  actual:   %q\n" "$qube_out" >&2
    exit 1
fi

echo "PASS: $qube_out"
