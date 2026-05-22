#!/usr/bin/env bash
# scripts/hello-roundtrip.sh
#
# End-to-end smoke test for the back-half of the pipeline:
#
#   q64 emit-hello → hello.wasm → q64-wasmtime-host → stdout
#
# Builds both binaries, runs the codegen, pipes the resulting wasm
# through the wasmtime runtime adapter, and asserts that stdout
# matches the expected "Hello, q64.\n".
#
# Fails fast on any step. Intended for CI and local verification.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ZIG="$REPO_ROOT/vendor/zig/zig"
Q64_BIN="$REPO_ROOT/q64/zig-out/bin/q64"
HOST_BIN="$REPO_ROOT/runtime/wasmtime/zig-out/bin/q64-wasmtime-host"

if [[ ! -x "$ZIG" ]]; then
    echo "error: pinned zig not found at $ZIG — run ./init.sh first" >&2
    exit 2
fi

echo "==> building q64"
"$ZIG" build --build-file "$REPO_ROOT/q64/build.zig"

echo "==> building wasmtime runtime adapter"
"$ZIG" build --build-file "$REPO_ROOT/runtime/wasmtime/build.zig"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

wasm="$tmp/hello.wasm"

echo "==> q64 emit-hello $wasm"
"$Q64_BIN" emit-hello "$wasm"

if [[ ! -s "$wasm" ]]; then
    echo "FAIL: emit-hello produced an empty file" >&2
    exit 1
fi

echo "==> $HOST_BIN $wasm"
actual="$("$HOST_BIN" "$wasm")"
expected="Hello, q64."

if [[ "$actual" != "$expected" ]]; then
    echo "FAIL: output mismatch" >&2
    printf "  expected: %q\n" "$expected" >&2
    printf "  actual:   %q\n" "$actual" >&2
    exit 1
fi

echo "PASS: $actual"
