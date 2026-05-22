#!/usr/bin/env bash
# init.sh — set up the q64 dev environment.
#
# Pins and installs:
#   - the Zig toolchain (vendor/zig/) — used to build q64/, qube/, and
#     each runtime adapter.
#   - the wasmtime C API (vendor/wasmtime/) — used by
#     runtime/wasmtime/ to embed wasm modules and provide q64's
#     capability-face imports (env.out, …).
#
# Re-runnable; skips work that's already done. Run from the repo root:
#
#     ./init.sh
#
# After it succeeds, add the Zig toolchain to PATH for this shell:
#
#     . ./vendor/zig/activate
#
# or:
#
#     export PATH="$PWD/vendor/zig:$PATH"
#
# Pinned versions can be overridden via env:
#
#     ZIG_VERSION=0.14.1 ./init.sh
#     WASMTIME_VERSION=44.0.0 WASMTIME_SHA256=… ./init.sh

set -euo pipefail

ZIG_VERSION="${ZIG_VERSION:-0.14.0}"
ZIG_DEST="vendor/zig"
ZIG_INDEX_URL="https://ziglang.org/download/index.json"

WASMTIME_VERSION="${WASMTIME_VERSION:-45.0.0}"
WASMTIME_DEST="vendor/wasmtime"
WASMTIME_RELEASE_BASE="https://github.com/bytecodealliance/wasmtime/releases/download"

cd "$(dirname "$0")"

# --- platform detection ------------------------------------------------

uname_s="$(uname -s)"
uname_m="$(uname -m)"

case "$uname_s" in
    Linux)  os="linux"  ;;
    Darwin) os="macos"  ;;
    *)
        echo "init.sh: unsupported OS '$uname_s' (need Linux or macOS)" >&2
        exit 1
        ;;
esac

case "$uname_m" in
    x86_64|amd64)  arch="x86_64"  ;;
    aarch64|arm64) arch="aarch64" ;;
    *)
        echo "init.sh: unsupported arch '$uname_m' (need x86_64 or aarch64)" >&2
        exit 1
        ;;
esac

# Zig's index.json keys builds by "<arch>-<os>" (e.g. "x86_64-linux").
ZIG_TRIPLE="${arch}-${os}"

# --- required tools ----------------------------------------------------

for cmd in curl python3 tar; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "init.sh: missing required tool: $cmd" >&2
        exit 1
    fi
done

if command -v sha256sum >/dev/null 2>&1; then
    sha256_cmd=(sha256sum)
elif command -v shasum >/dev/null 2>&1; then
    sha256_cmd=(shasum -a 256)
else
    echo "init.sh: need sha256sum or shasum to verify downloads" >&2
    exit 1
fi

# --- shared workdir ----------------------------------------------------

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# =====================================================================
# Zig
# =====================================================================

install_zig() {
    if [ -x "$ZIG_DEST/zig" ]; then
        installed_version="$("$ZIG_DEST/zig" version 2>/dev/null || echo unknown)"
        if [ "$installed_version" = "$ZIG_VERSION" ]; then
            echo "init.sh: zig $ZIG_VERSION already installed at $ZIG_DEST"
            return
        fi
        echo "init.sh: replacing existing zig $installed_version with $ZIG_VERSION"
    fi

    # Pull the tarball URL and SHA-256 from ziglang.org's release index
    # so we don't have to hand-pin per-platform hashes that would go
    # stale. The HTTPS connection to ziglang.org is the trust root.
    echo "init.sh: fetching release index from $ZIG_INDEX_URL"
    meta="$(curl -fsSL "$ZIG_INDEX_URL" | python3 -c "
import json, sys
idx = json.load(sys.stdin)
v, t = '$ZIG_VERSION', '$ZIG_TRIPLE'
if v not in idx:
    sys.exit(f'init.sh: zig {v!r} not found in release index')
e = idx[v].get(t)
if not e:
    sys.exit(f'init.sh: zig {v} has no {t} build in the release index')
print(e['tarball'], e['shasum'])
")"

    read -r tarball_url expected_sha <<< "$meta"
    if [ -z "${tarball_url:-}" ] || [ -z "${expected_sha:-}" ]; then
        echo "init.sh: failed to read release metadata from index.json" >&2
        exit 1
    fi

    tarball_name="$(basename "$tarball_url")"
    echo "init.sh: downloading $tarball_url"
    curl -fsSL "$tarball_url" -o "$tmpdir/$tarball_name"

    actual_sha="$("${sha256_cmd[@]}" "$tmpdir/$tarball_name" | awk '{print $1}')"
    if [ "$actual_sha" != "$expected_sha" ]; then
        echo "init.sh: zig sha256 mismatch:" >&2
        echo "  expected: $expected_sha" >&2
        echo "  got:      $actual_sha" >&2
        exit 1
    fi
    echo "init.sh: zig sha256 verified ($actual_sha)"

    echo "init.sh: extracting to $ZIG_DEST"
    mkdir -p "$(dirname "$ZIG_DEST")"
    tar -xJf "$tmpdir/$tarball_name" -C "$tmpdir"

    extracted_dir="$tmpdir/${tarball_name%.tar.xz}"
    if [ ! -d "$extracted_dir" ]; then
        echo "init.sh: unexpected tarball layout — no $extracted_dir after extract" >&2
        exit 1
    fi

    rm -rf "$ZIG_DEST"
    mv "$extracted_dir" "$ZIG_DEST"

    cat > "$ZIG_DEST/activate" <<'EOF'
# Source from the repo root to add the pinned zig to PATH:
#     . ./vendor/zig/activate
_zig_bin="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
case ":$PATH:" in
    *":$_zig_bin:"*) ;;
    *) PATH="$_zig_bin:$PATH" ;;
esac
unset _zig_bin
export PATH
EOF

    echo "init.sh: zig $("$ZIG_DEST/zig" version) installed at $ZIG_DEST"
}

# =====================================================================
# Wasmtime (C API)
# =====================================================================
#
# The wasmtime release archive name follows the pattern
#   wasmtime-v<version>-<arch>-<os>-c-api.tar.xz
# and extracts to a directory named after the tarball's basename.
# The archive ships both libwasmtime.so and libwasmtime.a, plus the
# headers in include/. We move the relevant subtree to vendor/wasmtime/
# so build.zig can find a stable layout.
#
# Hashes for the pinned version live in $WASMTIME_KNOWN_SHA256 below.
# For unlisted platforms set WASMTIME_SHA256 in the environment.

# triple -> sha256 for the pinned WASMTIME_VERSION. Add new platforms
# by running ./init.sh on the target with WASMTIME_SHA256=skip then
# pasting the printed hash here.
WASMTIME_KNOWN_SHA256_x86_64_linux="95959e7a4cc4bfc12bbe45c9dea82cf45dd5b4321d9163e66343c50728429129"

install_wasmtime() {
    if [ -f "$WASMTIME_DEST/lib/libwasmtime.so" ] && \
       [ "$(cat "$WASMTIME_DEST/VERSION" 2>/dev/null)" = "$WASMTIME_VERSION" ]; then
        echo "init.sh: wasmtime $WASMTIME_VERSION already installed at $WASMTIME_DEST"
        return
    fi

    local tarball="wasmtime-v${WASMTIME_VERSION}-${arch}-${os}-c-api.tar.xz"
    local url="${WASMTIME_RELEASE_BASE}/v${WASMTIME_VERSION}/${tarball}"

    # Resolve expected sha from the pinned table or the env override.
    local key="WASMTIME_KNOWN_SHA256_${arch}_${os}"
    local expected_sha="${WASMTIME_SHA256:-${!key:-}}"
    if [ -z "$expected_sha" ]; then
        echo "init.sh: no pinned sha256 for wasmtime ${WASMTIME_VERSION} on ${arch}-${os}." >&2
        echo "        Re-run with WASMTIME_SHA256=<sha> (or =skip to bypass verification)." >&2
        exit 1
    fi

    echo "init.sh: downloading $url"
    curl -fsSL "$url" -o "$tmpdir/$tarball"

    if [ "$expected_sha" != "skip" ]; then
        local actual_sha
        actual_sha="$("${sha256_cmd[@]}" "$tmpdir/$tarball" | awk '{print $1}')"
        if [ "$actual_sha" != "$expected_sha" ]; then
            echo "init.sh: wasmtime sha256 mismatch:" >&2
            echo "  expected: $expected_sha" >&2
            echo "  got:      $actual_sha" >&2
            exit 1
        fi
        echo "init.sh: wasmtime sha256 verified ($actual_sha)"
    else
        echo "init.sh: skipping wasmtime sha256 verification (WASMTIME_SHA256=skip)"
    fi

    echo "init.sh: extracting to $WASMTIME_DEST"
    mkdir -p "$(dirname "$WASMTIME_DEST")"
    tar -xJf "$tmpdir/$tarball" -C "$tmpdir"

    local extracted_dir="$tmpdir/${tarball%.tar.xz}"
    if [ ! -d "$extracted_dir" ]; then
        echo "init.sh: unexpected tarball layout — no $extracted_dir after extract" >&2
        exit 1
    fi

    rm -rf "$WASMTIME_DEST"
    mv "$extracted_dir" "$WASMTIME_DEST"
    echo "$WASMTIME_VERSION" > "$WASMTIME_DEST/VERSION"

    echo "init.sh: wasmtime $WASMTIME_VERSION installed at $WASMTIME_DEST"
}

install_zig
install_wasmtime

echo
echo "Add zig to PATH for this shell:"
echo "    . ./$ZIG_DEST/activate"
echo "or:"
echo "    export PATH=\"\$PWD/$ZIG_DEST:\$PATH\""
