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

# Compile-time `let` bindings: a binding names a const value (literal or
# const call) and is referenced by later statements / interpolation.
echo "==> bindings: q64 emit let name/v + interpolation"
bind_app="$tmp/bind.q"
bind_wasm="$tmp/bind.wasm"
cat > "$bind_app" <<'Q64'
import dev.q64.strlib.{vshout}

fn main {
    let name = "world"
    let v = vshout()
    env.out("Hello, {name}! (q64 v{v})")
    env.out(name)
}
Q64
"$Q64_BIN" emit "$bind_app" "$bind_wasm" --module "dev.q64.strlib=$param_lib"
bind_out="$("$HOST_BIN" "$bind_wasm")"
bind_expected=$'Hello, world! (q64 v0.1.0)\nworld'
if [[ "$bind_out" != "$bind_expected" ]]; then
    echo "FAIL: let-binding output mismatch" >&2
    printf "  expected: %q\n" "$bind_expected" >&2
    printf "  actual:   %q\n" "$bind_out" >&2
    exit 1
fi
echo "    ok: let bindings + interpolation"

# Runtime binding: `let g = shout("hi")` isn't const-foldable, so g binds
# the call's (ptr, len) into _start locals and is referenced twice.
echo "==> bindings: q64 emit runtime let g = shout(\"hi\")"
rt_app="$tmp/rt.q"
rt_wasm="$tmp/rt.wasm"
cat > "$rt_app" <<'Q64'
import dev.q64.strlib.{shout}

fn main {
    let g = shout("hi")
    env.out(g)
    env.out("got: {g} and {g}")
}
Q64
"$Q64_BIN" emit "$rt_app" "$rt_wasm" --module "dev.q64.strlib=$param_lib"
rt_out="$("$HOST_BIN" "$rt_wasm")"
rt_expected=$'hi!\ngot: hi! and hi!'
if [[ "$rt_out" != "$rt_expected" ]]; then
    echo "FAIL: runtime-binding output mismatch" >&2
    printf "  expected: %q\n" "$rt_expected" >&2
    printf "  actual:   %q\n" "$rt_out" >&2
    exit 1
fi
echo "    ok: runtime binding referenced multiple times"

# Runtime argument: a runtime binding is passed into another call, whose
# result is bound and referenced — the full bind → pass → bind → use flow.
echo "==> bindings: q64 emit runtime arg wrap(g)"
printf 'pub fn wrap(s: str) -> str { "[{s}]" }\n' >> "$param_lib/lib.q"
arg_app="$tmp/arg.q"
arg_wasm="$tmp/arg.wasm"
cat > "$arg_app" <<'Q64'
import dev.q64.strlib.{shout, wrap}

fn main {
    let g = shout("hi")
    env.out(wrap(g))
    let w = wrap(g)
    env.out("nested: {w}")
}
Q64
"$Q64_BIN" emit "$arg_app" "$arg_wasm" --module "dev.q64.strlib=$param_lib"
arg_out="$("$HOST_BIN" "$arg_wasm")"
arg_expected=$'[hi!]\nnested: [hi!]'
if [[ "$arg_out" != "$arg_expected" ]]; then
    echo "FAIL: runtime-argument output mismatch" >&2
    printf "  expected: %q\n" "$arg_expected" >&2
    printf "  actual:   %q\n" "$arg_out" >&2
    exit 1
fi
echo "    ok: runtime binding passed as an argument"

# Compile-time integer arithmetic: folded in the resolver and rendered to
# decimal (no runtime arithmetic). No dependency needed.
echo "==> arith: q64 emit \"{(1 + 2) * 3}\" etc."
arith_app="$tmp/arith.q"
arith_wasm="$tmp/arith.wasm"
cat > "$arith_app" <<'Q64'
fn main {
    let n = 6 * 7
    env.out("{(1 + 2) * 3} {n + 1} {1_000 + 24}")
}
Q64
"$Q64_BIN" emit "$arith_app" "$arith_wasm"
arith_out="$("$HOST_BIN" "$arith_wasm")"
if [[ "$arith_out" != "9 43 1024" ]]; then
    echo "FAIL: arithmetic output mismatch" >&2
    printf "  expected: %q\n" "9 43 1024" >&2
    printf "  actual:   %q\n" "$arith_out" >&2
    exit 1
fi
echo "    ok: const integer arithmetic -> $arith_out"

# Runtime i64 functions: typed params + real wasm arithmetic + int->string
# (__fmt_i64). double(n) references its parameter, so it can't const-fold.
echo "==> int fns: q64 emit env.out(double(21)) etc."
intfn_lib="$tmp/intlib/src"
mkdir -p "$intfn_lib"
cat > "$intfn_lib/lib.q" <<'Q64'
pub fn double(n: i64) -> i64 { n + n }
pub fn add(a: i64, b: i64) -> i64 { a + b }
pub fn neg(n: i64) -> i64 { 0 - n }
pub fn shout(s: str) -> str { "{s}!" }
Q64
intfn_app="$tmp/intfn.q"
intfn_wasm="$tmp/intfn.wasm"
cat > "$intfn_app" <<'Q64'
import dev.q64.intlib.{double, add, neg, shout}

fn main {
    env.out(double(21))
    env.out(add(1000000, 234567))
    env.out(neg(7))
    let a = double(21)
    env.out(add(a, 8))
    let b = add(a, 8)
    let g = shout("hi")
    env.out("{g}: a={a}, b={b}")
}
Q64
"$Q64_BIN" emit "$intfn_app" "$intfn_wasm" --module "dev.q64.intlib=$intfn_lib"
intfn_out="$("$HOST_BIN" "$intfn_wasm")"
intfn_expected=$'42\n1234567\n-7\n50\nhi!: a=42, b=50'
if [[ "$intfn_out" != "$intfn_expected" ]]; then
    echo "FAIL: runtime int-fn output mismatch" >&2
    printf "  expected: %q\n" "$intfn_expected" >&2
    printf "  actual:   %q\n" "$intfn_out" >&2
    exit 1
fi
echo "    ok: runtime i64 functions + bindings + interpolation -> ... / hi!: a=42, b=50"

echo "PASS: $qube_out"
