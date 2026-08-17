#!/usr/bin/env bash
# bench/run.sh — build and run the DSP kernel benchmarks, q64 vs the Rust
# baseline, and print a ns/sample comparison table.
#
# Prerequisites (all from the repo's own toolchain):
#   ./init.sh                                  # vendor/ toolchain
#   (cd q64 && zig build)                      # the compiler
#   (cd runtime/wasmtime && zig build)         # the embedded host
#   rustup target add wasm32-wasip1            # the baseline's target
#
# Overridable via env: Q64_BIN, Q64_WASMTIME_HOST, WASMTIME, CARGO.
set -euo pipefail
cd "$(dirname "$0")/.."

Q64="${Q64_BIN:-q64/zig-out/bin/q64}"
HOST="${Q64_WASMTIME_HOST:-runtime/wasmtime/zig-out/bin/q64-wasmtime-host}"
WASMTIME="${WASMTIME:-vendor/wasmtime/bin/wasmtime}"
CARGO="${CARGO:-cargo}"
OUT=bench/.out

for bin in "$Q64" "$HOST" "$WASMTIME"; do
    if [ ! -x "$bin" ]; then
        echo "bench: missing $bin — run ./init.sh and the zig builds (see header)" >&2
        exit 1
    fi
done

mkdir -p "$OUT"
results="$OUT/results.txt"
: > "$results"

echo "== q64 kernels (q64 emit --addr wasm32, embedded wasmtime host)"
for src in bench/kernels/*.q; do
    name=$(basename "$src" .q)
    "$Q64" emit "$src" "$OUT/$name.wasm" --addr wasm32
    line=$("$HOST" "$OUT/$name.wasm")
    echo "  $line"
    echo "q64 $line" >> "$results"
done

echo "== Rust baseline (wasm32-wasip1 --release, wasmtime CLI)"
# Run cargo from inside the crate: .cargo/config.toml (the +simd128 flag)
# is discovered from the working directory, not the manifest path.
(cd bench/baseline-rust && CARGO_TARGET_DIR="../../$OUT/rust-target" \
    "$CARGO" build --quiet --release --target wasm32-wasip1)
while IFS= read -r line; do
    echo "  $line"
    echo "rust $line" >> "$results"
done < <("$WASMTIME" run "$OUT/rust-target/wasm32-wasip1/release/baseline.wasm")

echo
awk '
$1 ~ /^(q64|rust)$/ && $2 == "bench" {
    lane = $1; name = $3; samples = $5; ns = $7; check = $9
    per = ns / samples
    if (lane == "q64") { q[name] = per; qc[name] = check }
    else { r[name] = per; rc[name] = check; if (!(name in seen)) { order[++n] = name; seen[name] = 1 } }
}
END {
    printf "%-14s %14s %14s %8s  %s\n", "kernel", "q64 ns/samp", "rust ns/samp", "ratio", "checksums (q64 | rust)"
    for (i = 1; i <= n; i++) {
        k = order[i]
        if (k in q) {
            printf "%-14s %14.2f %14.2f %7.1fx  %s | %s\n", k, q[k], r[k], q[k] / r[k], qc[k], rc[k]
        } else {
            printf "%-14s %14s %14.2f %8s\n", k, "-", r[k], "-"
        }
    }
}' "$results"
