#!/usr/bin/env bash
# init.sh — set up the q64 dev environment.
#
# Pins and installs:
#   - the Zig toolchain (vendor/zig/) — used to build q64/, qube/, and
#     each runtime adapter.
#   - the wasmtime C API (vendor/wasmtime/) — used by
#     runtime/wasmtime/ to embed wasm modules and provide q64's
#     capability-face imports (env.out, …).
#   - Binaryen (vendor/binaryen/) — used by q64/src/codegen/ to
#     assemble Wasm modules from the typed AST.
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

ZIG_VERSION="${ZIG_VERSION:-0.16.0}"
ZIG_DEST="vendor/zig"
ZIG_INDEX_URL="https://ziglang.org/download/index.json"

WASMTIME_VERSION="${WASMTIME_VERSION:-45.0.0}"
WASMTIME_DEST="vendor/wasmtime"
WASMTIME_RELEASE_BASE="https://github.com/bytecodealliance/wasmtime/releases/download"

BINARYEN_VERSION="${BINARYEN_VERSION:-129}"
BINARYEN_DEST="vendor/binaryen"
BINARYEN_REPO="https://github.com/WebAssembly/binaryen.git"

cd "$(dirname "$0")"

# --- platform detection ------------------------------------------------

uname_s="$(uname -s)"
uname_m="$(uname -m)"

case "$uname_s" in
    Linux)  os="linux"; shlib_ext="so"    ;;
    Darwin) os="macos"; shlib_ext="dylib" ;;
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

for cmd in curl python3 tar git cmake; do
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
    if [ -f "$WASMTIME_DEST/lib/libwasmtime.$shlib_ext" ] && \
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

# =====================================================================
# Binaryen (Wasm assembler / optimizer; C API for codegen)
# =====================================================================
#
# Built from source so the same artifact shape (static libbinaryen.a +
# headers) lands on Linux, macOS, and Windows. Upstream's prebuilt
# tarballs vary per-OS (macOS ships only a dylib; Linux ships .a linked
# against libstdc++; Windows ships MSVC .lib), which made cross-platform
# linking a per-OS dance. Building once with cmake -DBUILD_STATIC_LIB=ON
# yields a single rule in q64/build.zig: linkLibCpp + addObjectFile.

install_binaryen() {
    if [ -f "$BINARYEN_DEST/lib/libbinaryen.a" ] && \
       [ "$(cat "$BINARYEN_DEST/VERSION" 2>/dev/null)" = "$BINARYEN_VERSION" ]; then
        echo "init.sh: binaryen $BINARYEN_VERSION already installed at $BINARYEN_DEST"
        return
    fi

    # Fast path: pull a prebuilt static lib from an external cache, skipping the
    # ~10-minute from-source build. The cache URL is intentionally NOT hardcoded
    # here — it stays out of this public repo and is supplied via
    # BINARYEN_CACHE_URL by the environment that knows it (see qubepods'
    # scripts/setup-q64-toolchain.sh, which hosts the prebuilt lib in a
    # public-read R2 bucket). The cached tarball unpacks to a top-level
    # `binaryen/` dir matching the short-circuit above; any miss or error falls
    # through to the source build below, so this is purely an accelerator.
    if [ -n "${BINARYEN_CACHE_URL:-}" ]; then
        local c_arch c_os c_key c_url c_tar
        c_arch="$(uname -m)"; case "$c_arch" in amd64) c_arch=x86_64;; arm64) c_arch=aarch64;; esac
        c_os="$(uname -s | tr '[:upper:]' '[:lower:]')"
        c_key="binaryen-${BINARYEN_VERSION}-${c_arch}-${c_os}.tar.gz"
        c_url="${BINARYEN_CACHE_URL%/}/$c_key"
        c_tar="$tmpdir/$c_key"
        echo "init.sh: trying binaryen cache $c_url"
        if curl -fsSL "$c_url" -o "$c_tar" && [ -s "$c_tar" ]; then
            mkdir -p "$(dirname "$BINARYEN_DEST")"
            tar -xzf "$c_tar" -C "$(dirname "$BINARYEN_DEST")"
            if [ -f "$BINARYEN_DEST/lib/libbinaryen.a" ] && \
               [ "$(cat "$BINARYEN_DEST/VERSION" 2>/dev/null)" = "$BINARYEN_VERSION" ]; then
                echo "init.sh: restored prebuilt binaryen $BINARYEN_VERSION from cache"
                return
            fi
            echo "init.sh: cache tarball did not yield binaryen $BINARYEN_VERSION; building from source" >&2
        else
            echo "init.sh: binaryen cache miss/unavailable; building from source"
        fi
    fi

    local src="$tmpdir/binaryen-src"
    local build="$tmpdir/binaryen-build"
    local tag="version_${BINARYEN_VERSION}"

    echo "init.sh: cloning binaryen $tag from $BINARYEN_REPO"
    git clone --depth 1 --branch "$tag" --recurse-submodules "$BINARYEN_REPO" "$src"

    echo "init.sh: configuring binaryen (cmake)"
    cmake -S "$src" -B "$build" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_STATIC_LIB=ON \
        -DBUILD_TESTS=OFF \
        -DBUILD_TOOLS=OFF \
        -DENABLE_WERROR=OFF \
        >/dev/null

    # Cap parallelism. Binaryen's C++ TUs each peak around ~1 GB of RAM
    # to compile; an unbounded -j spawns one job per core and can swap a
    # laptop into a freeze. Leave one core free, and let callers override
    # via BINARYEN_JOBS.
    local jobs="${BINARYEN_JOBS:-}"
    if [ -z "$jobs" ]; then
        local ncpu
        if command -v nproc >/dev/null 2>&1; then
            ncpu="$(nproc)"
        elif command -v sysctl >/dev/null 2>&1; then
            ncpu="$(sysctl -n hw.ncpu 2>/dev/null || echo 2)"
        else
            ncpu=2
        fi
        jobs=$(( ncpu > 1 ? ncpu - 1 : 1 ))
    fi

    echo "init.sh: building binaryen with -j$jobs (override with BINARYEN_JOBS)"
    cmake --build "$build" --target binaryen --config Release -j"$jobs"

    # Locate the static archive. cmake's output dir varies a bit by
    # generator / version, so search rather than hard-code.
    local archive
    archive="$(find "$build" -name 'libbinaryen.a' -print -quit)"
    if [ -z "$archive" ] || [ ! -f "$archive" ]; then
        echo "init.sh: cmake build did not produce libbinaryen.a under $build" >&2
        exit 1
    fi

    echo "init.sh: installing into $BINARYEN_DEST"
    rm -rf "$BINARYEN_DEST"
    mkdir -p "$BINARYEN_DEST/include" "$BINARYEN_DEST/lib"
    cp "$archive" "$BINARYEN_DEST/lib/libbinaryen.a"
    # Public C API header + its .def dependencies live under src/.
    cp "$src/src/binaryen-c.h" "$BINARYEN_DEST/include/"
    if [ -f "$src/src/wasm-delegations.def" ]; then
        cp "$src/src/wasm-delegations.def" "$BINARYEN_DEST/include/"
    fi
    echo "$BINARYEN_VERSION" > "$BINARYEN_DEST/VERSION"

    echo "init.sh: binaryen $BINARYEN_VERSION installed at $BINARYEN_DEST"
}

install_zig
install_wasmtime
install_binaryen

echo
echo "Add zig to PATH for this shell:"
echo "    . ./$ZIG_DEST/activate"
echo "or:"
echo "    export PATH=\"\$PWD/$ZIG_DEST:\$PATH\""
