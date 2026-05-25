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

# Runtime string concatenation: an interpolation with literal text around a
# real call (`"q64 v{version()} ok"`) is built in the scope arena at run
# time (bump alloc + memory.copy), not const-folded. Reuses the demo lib.
echo "==> concat: q64 emit \"q64 v{version()} ok\""
concat_app="$tmp/concat.q"
concat_wasm="$tmp/concat.wasm"
cat > "$concat_app" <<'Q64'
import dev.q64.hello_world.{version}

fn main {
    env.out("q64 v{version()} ok")
}
Q64
"$Q64_BIN" emit "$concat_app" "$concat_wasm" --module "dev.q64.hello_world=$LIB_SRC"
concat_out="$("$HOST_BIN" "$concat_wasm")"
concat_expected="q64 v0.1.0 ok"
if [[ "$concat_out" != "$concat_expected" ]]; then
    echo "FAIL: concat output mismatch" >&2
    printf "  expected: %q\n" "$concat_expected" >&2
    printf "  actual:   %q\n" "$concat_out" >&2
    exit 1
fi
echo "    ok: arena concat -> $concat_out"

# String parameters + argument passing: a passthrough `id(s) { s }` takes
# a str (lowered to two i64 params), and the caller passes a literal.
echo "==> params: q64 emit env.out(id(\"passed\"))"
param_lib="$tmp/strlib/src"
mkdir -p "$param_lib"
printf 'pub fn id(s: str) -> str { s }\n' > "$param_lib/lib.q"
param_app="$tmp/param.q"
param_wasm="$tmp/param.wasm"
cat > "$param_app" <<'Q64'
import dev.q64.strlib.{id}

fn main {
    env.out(id("passed"))
}
Q64
"$Q64_BIN" emit "$param_app" "$param_wasm" --module "dev.q64.strlib=$param_lib"
param_out="$("$HOST_BIN" "$param_wasm")"
if [[ "$param_out" != "passed" ]]; then
    echo "FAIL: param output mismatch" >&2
    printf "  expected: %q\n" "passed" >&2
    printf "  actual:   %q\n" "$param_out" >&2
    exit 1
fi
echo "    ok: string param passthrough -> $param_out"

# Parameterized body that transforms its argument: `shout(s) { "{s}!" }`
# builds its result in the arena from a param segment + the literal "!".
echo "==> params: q64 emit env.out(shout(\"loud\"))"
printf 'pub fn shout(s: str) -> str { "{s}!" }\n' >> "$param_lib/lib.q"
shout_app="$tmp/shout.q"
shout_wasm="$tmp/shout.wasm"
cat > "$shout_app" <<'Q64'
import dev.q64.strlib.{shout}

fn main {
    env.out(shout("loud"))
}
Q64
"$Q64_BIN" emit "$shout_app" "$shout_wasm" --module "dev.q64.strlib=$param_lib"
shout_out="$("$HOST_BIN" "$shout_wasm")"
if [[ "$shout_out" != "loud!" ]]; then
    echo "FAIL: param-transform output mismatch" >&2
    printf "  expected: %q\n" "loud!" >&2
    printf "  actual:   %q\n" "$shout_out" >&2
    exit 1
fi
echo "    ok: param transform -> $shout_out"

# Multi-argument function + a const-foldable call passed as an argument.
echo "==> params: q64 emit join(\"a\", \"b\") and shout(version())"
{
  printf 'pub fn join(a: str, b: str) -> str { "{a}-{b}" }\n'
  printf 'pub fn vshout() -> str { "0.1.0" }\n'
} >> "$param_lib/lib.q"
multi_app="$tmp/multi.q"
multi_wasm="$tmp/multi.wasm"
cat > "$multi_app" <<'Q64'
import dev.q64.strlib.{join, shout, vshout}

fn main {
    env.out(join("a", "b"))
    env.out(shout(vshout()))
}
Q64
"$Q64_BIN" emit "$multi_app" "$multi_wasm" --module "dev.q64.strlib=$param_lib"
multi_out="$("$HOST_BIN" "$multi_wasm")"
multi_expected=$'a-b\n0.1.0!'
if [[ "$multi_out" != "$multi_expected" ]]; then
    echo "FAIL: multi-arg/compose output mismatch" >&2
    printf "  expected: %q\n" "$multi_expected" >&2
    printf "  actual:   %q\n" "$multi_out" >&2
    exit 1
fi
echo "    ok: multi-arg + composed call arg"

echo "PASS: $qube_out"
