#!/usr/bin/env bash
# init.sh — set up the q64 dev environment.
#
# Pins and installs:
#   - the Zig toolchain (vendor/zig/) — used to build q64/, qube/, and
#     each runtime adapter.
#   - the wasmtime C API (vendor/wasmtime/) — used by
#     runtime/wasmtime/ to embed wasm modules and provide q64's
#     capability-face imports (env.out, …).
#   - the wasmtime CLI (vendor/wasmtime/bin/wasmtime) — OPTIONAL: the
#     WASIp3-capable component runner (`wasmtime run -S p3`). The embedded
#     C API only exposes WASIp2; the CLI is how the component-roundtrip
#     runs an app component under the async WASIp3 runtime. sha256-pinned;
#     skipped where unpinned.
#   - Binaryen (vendor/binaryen/) — used by q64/src/codegen/ to
#     assemble Wasm modules from the typed AST.
#   - wabt / wat2wasm (vendor/wabt/) — OPTIONAL: compile WAT fixtures +
#     component helper modules and inspect emitted wasm. sha256-pinned;
#     skipped on platforms without a pinned hash (the core build never
#     needs it).
#   - wasm-tools (vendor/wasm-tools/) — OPTIONAL: component-model tooling
#     (validate / WIT extraction / component new); used to differential-test
#     the q64 component encoder. sha256-pinned; skipped where unpinned.
#   - WASI preview1 adapter (vendor/wasi/) — OPTIONAL: the shim `wasm-tools
#     component new --adapt` uses to wrap a preview1 core module into a real
#     wasi:cli/* component. sha256-pinned.
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
# Same fetch model as wabt / wasm-tools / the WASI adapter: a public CDN mirror
# (cdn.q64.dev/toolchain, same upstream archive under the same name) tried first,
# the github.com release as the fallback, both checked against the same pin. This
# matters in sandboxed/proxied environments where github release-asset downloads
# are blocked but the CDN is reachable — the C API download used to be the one
# toolchain step with no mirror, so its failure aborted the whole bootstrap.
WASMTIME_CACHE_URL="${WASMTIME_CACHE_URL-https://cdn.q64.dev/toolchain}"

BINARYEN_VERSION="${BINARYEN_VERSION:-129}"
BINARYEN_DEST="vendor/binaryen"
BINARYEN_REPO="https://github.com/WebAssembly/binaryen.git"
# Prebuilt-cache accelerator (a top-level `binaryen/` tarball: static lib +
# headers) — skips the ~10-minute from-source build. Defaults to q64's public
# CDN bucket under `toolchain/`; verified against the pinned sha256 below, with
# the from-source build as the fallback on miss / mismatch / unpinned platform.
BINARYEN_CACHE_URL="${BINARYEN_CACHE_URL-https://cdn.q64.dev/toolchain}"
BINARYEN_CACHE_SHA256_x86_64_linux="b5832372417ab28bc8c2a32e4404d85110e04a33c4a5dc57206af71eb1145503"
BINARYEN_CACHE_SHA256_aarch64_linux="737be1ea11586d7bbc00723d29eb76cdad82851e59520579dee6d3ea57e19062"
BINARYEN_CACHE_SHA256_aarch64_darwin="d6d00cfec33fdf9cd0324be5c6d7606579b0877ad59338ef7d2d0c28bac9ac38"
BINARYEN_CACHE_SHA256_x86_64_darwin="30ac3d1da0fc183e41df93708f3a7391443cff9bc8aa7a217098ae1fdb91d14e"
BINARYEN_CACHE_SHA256_aarch64_windows="04f3d2cdfb0b5818807845669c37fe734ef040fe1657e2aa62dda77142d85853"

# wabt (wat2wasm / wasm2wat) — OPTIONAL developer tooling: compile the WAT
# fixtures + component helper modules to wasm, and inspect emitted modules.
# The toolchain (q64, host, codegen) does NOT require it; a platform without a
# pinned hash just skips it. Trust root is the pinned sha256 below — verified
# whatever the source. WABT_CACHE_URL defaults to q64's public CDN bucket
# (cdn.q64.dev, bucket `q64`) under the `toolchain/` prefix, which mirrors the
# upstream release tarball by its asset name (object key
# `toolchain/wabt-<ver>-<os>.tar.gz`); init.sh tries the CDN first and falls
# back to github.com on a miss. The pin makes the mirror safe regardless.
# Override the URL (or set it empty) to force the upstream release.
WABT_VERSION="${WABT_VERSION:-1.0.37}"
WABT_DEST="vendor/wabt"
WABT_RELEASE_BASE="https://github.com/WebAssembly/wabt/releases/download"
WABT_CACHE_URL="${WABT_CACHE_URL-https://cdn.q64.dev/toolchain}"

# wasm-tools — OPTIONAL: the component-model swiss-army knife (validate / print
# / parse components, extract a component's WIT world, `component new/embed`).
# Used to differential-test the q64 component encoder against the reference
# implementation. Not needed for the core build. Same fetch model as wabt: the
# public CDN mirror, sha256-pinned, github.com as fallback. The upstream release
# tag carries a `v` prefix (v<ver>); the asset basename does not.
WASMTOOLS_VERSION="${WASMTOOLS_VERSION:-1.251.0}"
WASMTOOLS_DEST="vendor/wasm-tools"
WASMTOOLS_RELEASE_BASE="https://github.com/bytecodealliance/wasm-tools/releases/download"
WASMTOOLS_CACHE_URL="${WASMTOOLS_CACHE_URL-https://cdn.q64.dev/toolchain}"

# WASI Preview 1 adapter (a single .wasm) — OPTIONAL: the official preview1->
# preview2 shim `wasm-tools component new --adapt` uses to wrap a preview1 core
# module (one that imports wasi_snapshot_preview1.*) into a real wasi:cli/*
# component. Tied to the wasmtime version. CDN mirror (versioned name) first,
# the wasmtime release (unversioned name) as fallback; sha256-pinned.
WASI_ADAPTER_VERSION="${WASI_ADAPTER_VERSION:-45.0.0}"
WASI_ADAPTER_DEST="vendor/wasi"
WASI_ADAPTER_RELEASE_BASE="https://github.com/bytecodealliance/wasmtime/releases/download"
WASI_ADAPTER_CACHE_URL="${WASI_ADAPTER_CACHE_URL-https://cdn.q64.dev/toolchain}"
WASI_ADAPTER_SHA256="eb843effeade4b79d7b9e9bf0e21ba33c24c26d54f347414a1ba72bcb65fac74"

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

# The wasmtime *CLI* archive (no `-c-api` suffix) ships the `wasmtime` binary.
# We vendor it as the WASIp3 component runner (`wasmtime run -S p3`) — the C API
# we embed only implements WASIp2, so the CLI is how a WASIp3 (async) component
# is run end-to-end. triple -> sha256 for the pinned WASMTIME_VERSION; unlisted
# platforms skip (optional tooling) unless WASMTIME_CLI_SHA256 is set.
WASMTIME_CLI_KNOWN_SHA256_x86_64_linux="9d92e6dc04630f617e0e5d532327a5a917ac4898587e07f4fb7a5fc7fffef760"

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
        echo "init.sh: no pinned sha256 for wasmtime ${WASMTIME_VERSION} on ${arch}-${os} — skipping." >&2
        echo "        Set WASMTIME_SHA256=<sha> (or =skip) to vendor it; the wasm/LSP targets" >&2
        echo "        build without it, the native runtime (runtime/wasmtime/) needs it." >&2
        return 0
    fi

    # CDN mirror first, then the upstream release; both verified against the same
    # pin below. A total failure is non-fatal (matches the other vendored tools):
    # only the native runtime target needs the C API, so the bootstrap must not
    # abort here and strand the later steps (binaryen, etc.).
    local src=""
    if [ -n "${WASMTIME_CACHE_URL:-}" ] && \
       curl -fsSL "${WASMTIME_CACHE_URL%/}/$tarball" -o "$tmpdir/$tarball" 2>/dev/null && [ -s "$tmpdir/$tarball" ]; then
        src="cache (${WASMTIME_CACHE_URL})"
    elif curl -fsSL "$url" -o "$tmpdir/$tarball" 2>/dev/null && [ -s "$tmpdir/$tarball" ]; then
        src="release"
    else
        echo "init.sh: wasmtime C API download failed (CDN mirror + $url) — skipping." >&2
        echo "        The wasm/LSP/emit targets build without it; the native runtime" >&2
        echo "        (runtime/wasmtime/) needs it and will error at build time if absent." >&2
        return 0
    fi
    echo "init.sh: fetched wasmtime C API from $src"

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

# Vendor the wasmtime CLI binary (the WASIp3 runner) into
# vendor/wasmtime/bin/wasmtime. Optional: skipped on platforms without a pinned
# sha (the core build never needs it; only the component-roundtrip run step
# does). Must run *after* install_wasmtime, which owns $WASMTIME_DEST.
install_wasmtime_cli() {
    local cli_dest="$WASMTIME_DEST/bin/wasmtime"
    if [ -x "$cli_dest" ] && \
       [ "$("$cli_dest" --version 2>/dev/null | awk '{print $2}')" = "$WASMTIME_VERSION" ]; then
        echo "init.sh: wasmtime CLI $WASMTIME_VERSION already installed at $cli_dest"
        return
    fi

    local tarball="wasmtime-v${WASMTIME_VERSION}-${arch}-${os}.tar.xz"
    local url="${WASMTIME_RELEASE_BASE}/v${WASMTIME_VERSION}/${tarball}"
    local key="WASMTIME_CLI_KNOWN_SHA256_${arch}_${os}"
    local expected_sha="${WASMTIME_CLI_SHA256:-${!key:-}}"
    if [ -z "$expected_sha" ]; then
        echo "init.sh: no pinned sha256 for the wasmtime CLI on ${arch}-${os} — skipping (optional WASIp3 runner)." >&2
        return 0
    fi

    # CDN mirror first, then the upstream release; the same pin verifies either.
    if [ -n "${WASMTIME_CACHE_URL:-}" ] && \
       curl -fsSL "${WASMTIME_CACHE_URL%/}/$tarball" -o "$tmpdir/$tarball" 2>/dev/null && [ -s "$tmpdir/$tarball" ]; then
        echo "init.sh: fetched wasmtime CLI from cache (${WASMTIME_CACHE_URL})"
    elif curl -fsSL "$url" -o "$tmpdir/$tarball" 2>/dev/null && [ -s "$tmpdir/$tarball" ]; then
        echo "init.sh: fetched wasmtime CLI from release"
    else
        echo "init.sh: wasmtime CLI download failed (CDN mirror + $url) — skipping (optional WASIp3 runner)" >&2
        return 0
    fi

    if [ "$expected_sha" != "skip" ]; then
        local actual_sha
        actual_sha="$("${sha256_cmd[@]}" "$tmpdir/$tarball" | awk '{print $1}')"
        if [ "$actual_sha" != "$expected_sha" ]; then
            echo "init.sh: wasmtime CLI sha256 mismatch — refusing:" >&2
            echo "  expected: $expected_sha" >&2
            echo "  got:      $actual_sha" >&2
            exit 1
        fi
        echo "init.sh: wasmtime CLI sha256 verified ($actual_sha)"
    else
        echo "init.sh: skipping wasmtime CLI sha256 verification (WASMTIME_CLI_SHA256=skip)"
    fi

    tar -xJf "$tmpdir/$tarball" -C "$tmpdir"
    local extracted_dir="$tmpdir/wasmtime-v${WASMTIME_VERSION}-${arch}-${os}"
    if [ ! -x "$extracted_dir/wasmtime" ]; then
        echo "init.sh: unexpected CLI tarball layout — no $extracted_dir/wasmtime" >&2
        exit 1
    fi
    mkdir -p "$WASMTIME_DEST/bin"
    cp "$extracted_dir/wasmtime" "$cli_dest"
    chmod +x "$cli_dest"
    echo "init.sh: wasmtime CLI $WASMTIME_VERSION installed at $cli_dest"
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

    # Fast path: pull a prebuilt static lib from q64's public CDN cache
    # (cdn.q64.dev/toolchain/, the same bucket as wabt), skipping the ~10-minute
    # from-source build. The cached tarball unpacks to a top-level `binaryen/`
    # dir matching the short-circuit above. The pinned sha256 is the trust root:
    # a download that doesn't match (or a platform with no pin, or any miss)
    # falls through to the source build below, so the cache is a safe accelerator.
    if [ -n "${BINARYEN_CACHE_URL:-}" ]; then
        local c_arch c_os c_key c_url c_tar pin_key pin got_sha
        c_arch="$(uname -m)"; case "$c_arch" in amd64) c_arch=x86_64;; arm64) c_arch=aarch64;; esac
        c_os="$(uname -s | tr '[:upper:]' '[:lower:]')"
        pin_key="BINARYEN_CACHE_SHA256_${c_arch}_${c_os}"
        pin="${!pin_key:-}"
        if [ -z "$pin" ]; then
            echo "init.sh: no pinned binaryen cache for ${c_arch}-${c_os}; building from source"
        else
            c_key="binaryen-${BINARYEN_VERSION}-${c_arch}-${c_os}.tar.gz"
            # Cache-bust the CDN edge by the pinned sha: when the lib's content
            # changes (e.g. a rebuild under a different C++ ABI) the query string
            # changes too, so Cloudflare can never serve a stale cached object
            # for a reused key. Unchanged content reuses the edge cache.
            c_url="${BINARYEN_CACHE_URL%/}/$c_key?v=$pin"
            c_tar="$tmpdir/$c_key"
            echo "init.sh: trying binaryen cache $c_url"
            if curl -fsSL "$c_url" -o "$c_tar" && [ -s "$c_tar" ]; then
                got_sha="$("${sha256_cmd[@]}" "$c_tar" | awk '{print $1}')"
                if [ "$got_sha" = "$pin" ]; then
                    echo "init.sh: binaryen cache sha256 verified ($got_sha)"
                    mkdir -p "$(dirname "$BINARYEN_DEST")"
                    tar -xzf "$c_tar" -C "$(dirname "$BINARYEN_DEST")"
                    if [ -f "$BINARYEN_DEST/lib/libbinaryen.a" ] && \
                       [ "$(cat "$BINARYEN_DEST/VERSION" 2>/dev/null)" = "$BINARYEN_VERSION" ]; then
                        echo "init.sh: restored prebuilt binaryen $BINARYEN_VERSION from cache"
                        return
                    fi
                    echo "init.sh: cache tarball did not yield binaryen $BINARYEN_VERSION; building from source" >&2
                else
                    echo "init.sh: binaryen cache sha256 mismatch — ignoring cache, building from source" >&2
                    echo "  expected: $pin" >&2
                    echo "  got:      $got_sha" >&2
                fi
            else
                echo "init.sh: binaryen cache miss/unavailable; building from source"
            fi
        fi
    fi

    local src="$tmpdir/binaryen-src"
    local build="$tmpdir/binaryen-build"
    local tag="version_${BINARYEN_VERSION}"

    echo "init.sh: cloning binaryen $tag from $BINARYEN_REPO"
    git clone --depth 1 --branch "$tag" --recurse-submodules "$BINARYEN_REPO" "$src"

    echo "init.sh: configuring binaryen (cmake)"
    # Build Binaryen with `zig c++`, not the host gcc, so libbinaryen.a carries
    # zig's libc++ ABI — matching q64/build.zig's `link_libcpp = true` on every
    # platform (the CDN cache libs are built the same way). A host-gcc build
    # would emit GNU libstdc++ symbols that won't resolve against libc++.
    local zig_abs zcc zcxx
    zig_abs="$(cd "$(dirname "$ZIG_DEST")" && pwd)/$(basename "$ZIG_DEST")/zig"
    zcc="$tmpdir/zig-cc"; zcxx="$tmpdir/zig-cxx"
    printf '#!/bin/sh\nexec "%s" cc "$@"\n'  "$zig_abs" > "$zcc";  chmod +x "$zcc"
    printf '#!/bin/sh\nexec "%s" c++ "$@"\n' "$zig_abs" > "$zcxx"; chmod +x "$zcxx"
    cmake -S "$src" -B "$build" \
        -DCMAKE_C_COMPILER="$zcc" \
        -DCMAKE_CXX_COMPILER="$zcxx" \
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

# =====================================================================
# wabt (wat2wasm / wasm2wat) — optional dev tooling, sha256-pinned
# =====================================================================
#
# Downloaded prebuilt from the upstream GitHub release and VERIFIED against a
# pinned sha256 (the security control: a tampered byte stream is rejected
# regardless of where it was fetched from). Optional WABT_CACHE_URL provides an
# R2 mirror — the same upstream tarball, so the same pin verifies it. A platform
# without a pinned hash is skipped (the core toolchain doesn't need wabt), and
# any failure is non-fatal.

# triple -> "<release-asset-basename>:<sha256>" for the pinned WABT_VERSION.
# Add a platform by downloading its release asset and pasting basename + hash.
WABT_KNOWN_x86_64_linux="wabt-${WABT_VERSION}-ubuntu-20.04.tar.gz:cfc675dc9b663d9adc8c75d982c1ba29f661448a2e026a67e71fe3f76a3e09f3"

# triple -> "<release-asset-basename>:<sha256>" for the pinned WASMTOOLS_VERSION.
WASMTOOLS_KNOWN_x86_64_linux="wasm-tools-${WASMTOOLS_VERSION}-x86_64-linux.tar.gz:08d523676ec71d9afbae05aa4255041ce91bf2d325d87b7e722d190d558be689"

install_wabt() {
    if [ -x "$WABT_DEST/bin/wat2wasm" ] && \
       [ "$(cat "$WABT_DEST/VERSION" 2>/dev/null)" = "$WABT_VERSION" ]; then
        echo "init.sh: wabt $WABT_VERSION already installed at $WABT_DEST"
        return 0
    fi

    local key="WABT_KNOWN_${arch}_${os}"
    local entry="${!key:-}"
    if [ -z "$entry" ]; then
        echo "init.sh: no pinned wat2wasm for ${arch}-${os} — skipping (optional tooling)"
        return 0
    fi
    local asset="${entry%%:*}"
    local expected_sha="${entry##*:}"
    local tarball="$tmpdir/$asset"

    # Try the optional R2 mirror first, then the upstream release. Either source
    # is checked against the same pinned sha256, so a bad mirror can't poison it.
    local got=""
    if [ -n "$WABT_CACHE_URL" ] && \
       curl -fsSL "${WABT_CACHE_URL%/}/$asset" -o "$tarball" 2>/dev/null && [ -s "$tarball" ]; then
        got="cache"
    elif curl -fsSL "${WABT_RELEASE_BASE}/${WABT_VERSION}/${asset}" -o "$tarball" 2>/dev/null && [ -s "$tarball" ]; then
        got="release"
    else
        echo "init.sh: wat2wasm download failed — skipping (optional tooling)" >&2
        return 0
    fi

    local actual_sha
    actual_sha="$("${sha256_cmd[@]}" "$tarball" | awk '{print $1}')"
    if [ "$actual_sha" != "$expected_sha" ]; then
        echo "init.sh: wabt sha256 mismatch (from $got) — refusing:" >&2
        echo "  expected: $expected_sha" >&2
        echo "  got:      $actual_sha" >&2
        return 0
    fi
    echo "init.sh: wabt sha256 verified ($actual_sha, from $got)"

    tar -xzf "$tarball" -C "$tmpdir"
    local extracted="$tmpdir/wabt-${WABT_VERSION}"
    if [ ! -d "$extracted" ]; then
        echo "init.sh: unexpected wabt tarball layout — skipping" >&2
        return 0
    fi
    rm -rf "$WABT_DEST"
    mv "$extracted" "$WABT_DEST"
    echo "$WABT_VERSION" > "$WABT_DEST/VERSION"
    echo "init.sh: wabt $WABT_VERSION installed at $WABT_DEST ($("$WABT_DEST/bin/wat2wasm" --version 2>/dev/null || echo '?'))"
}

# =====================================================================
# wasm-tools — optional component-model tooling, sha256-pinned
# =====================================================================

install_wasmtools() {
    if [ -x "$WASMTOOLS_DEST/wasm-tools" ] && \
       [ "$(cat "$WASMTOOLS_DEST/VERSION" 2>/dev/null)" = "$WASMTOOLS_VERSION" ]; then
        echo "init.sh: wasm-tools $WASMTOOLS_VERSION already installed at $WASMTOOLS_DEST"
        return 0
    fi

    local key="WASMTOOLS_KNOWN_${arch}_${os}"
    local entry="${!key:-}"
    if [ -z "$entry" ]; then
        echo "init.sh: no pinned wasm-tools for ${arch}-${os} — skipping (optional tooling)"
        return 0
    fi
    local asset="${entry%%:*}"
    local expected_sha="${entry##*:}"
    local tarball="$tmpdir/$asset"

    # CDN mirror first, then the upstream release (tag carries a `v` prefix).
    # Both are checked against the same pin, so a bad mirror can't poison it.
    local got=""
    if [ -n "$WASMTOOLS_CACHE_URL" ] && \
       curl -fsSL "${WASMTOOLS_CACHE_URL%/}/$asset" -o "$tarball" 2>/dev/null && [ -s "$tarball" ]; then
        got="cache"
    elif curl -fsSL "${WASMTOOLS_RELEASE_BASE}/v${WASMTOOLS_VERSION}/${asset}" -o "$tarball" 2>/dev/null && [ -s "$tarball" ]; then
        got="release"
    else
        echo "init.sh: wasm-tools download failed — skipping (optional tooling)" >&2
        return 0
    fi

    local actual_sha
    actual_sha="$("${sha256_cmd[@]}" "$tarball" | awk '{print $1}')"
    if [ "$actual_sha" != "$expected_sha" ]; then
        echo "init.sh: wasm-tools sha256 mismatch (from $got) — refusing:" >&2
        echo "  expected: $expected_sha" >&2
        echo "  got:      $actual_sha" >&2
        return 0
    fi
    echo "init.sh: wasm-tools sha256 verified ($actual_sha, from $got)"

    tar -xzf "$tarball" -C "$tmpdir"
    # The tarball extracts to a dir named after the asset basename.
    local extracted="$tmpdir/${asset%.tar.gz}"
    if [ ! -x "$extracted/wasm-tools" ]; then
        echo "init.sh: unexpected wasm-tools tarball layout — skipping" >&2
        return 0
    fi
    rm -rf "$WASMTOOLS_DEST"
    mv "$extracted" "$WASMTOOLS_DEST"
    echo "$WASMTOOLS_VERSION" > "$WASMTOOLS_DEST/VERSION"
    echo "init.sh: wasm-tools $WASMTOOLS_VERSION installed at $WASMTOOLS_DEST ($("$WASMTOOLS_DEST/wasm-tools" --version 2>/dev/null || echo '?'))"
}

# =====================================================================
# wasi adapter — optional preview1->preview2 shim, sha256-pinned
# =====================================================================

install_wasi_adapter() {
    local file="$WASI_ADAPTER_DEST/wasi_snapshot_preview1.command.wasm"
    if [ -f "$file" ] && \
       [ "$(cat "$WASI_ADAPTER_DEST/VERSION" 2>/dev/null)" = "$WASI_ADAPTER_VERSION" ]; then
        echo "init.sh: wasi adapter $WASI_ADAPTER_VERSION already installed at $WASI_ADAPTER_DEST"
        return 0
    fi

    # A single .wasm (not a tarball). The CDN mirror uses a versioned object
    # name; the wasmtime release uses the unversioned name. Both are checked
    # against the same pin, so a bad mirror can't poison it.
    local cdn_name="wasi_snapshot_preview1.command-${WASI_ADAPTER_VERSION}.wasm"
    local rel_name="wasi_snapshot_preview1.command.wasm"
    local out="$tmpdir/wasi-adapter.wasm"
    local got=""
    if [ -n "$WASI_ADAPTER_CACHE_URL" ] && \
       curl -fsSL "${WASI_ADAPTER_CACHE_URL%/}/$cdn_name" -o "$out" 2>/dev/null && [ -s "$out" ]; then
        got="cache"
    elif curl -fsSL "${WASI_ADAPTER_RELEASE_BASE}/v${WASI_ADAPTER_VERSION}/${rel_name}" -o "$out" 2>/dev/null && [ -s "$out" ]; then
        got="release"
    else
        echo "init.sh: wasi adapter download failed — skipping (optional tooling)" >&2
        return 0
    fi

    local actual_sha
    actual_sha="$("${sha256_cmd[@]}" "$out" | awk '{print $1}')"
    if [ "$actual_sha" != "$WASI_ADAPTER_SHA256" ]; then
        echo "init.sh: wasi adapter sha256 mismatch (from $got) — refusing:" >&2
        echo "  expected: $WASI_ADAPTER_SHA256" >&2
        echo "  got:      $actual_sha" >&2
        return 0
    fi
    echo "init.sh: wasi adapter sha256 verified ($actual_sha, from $got)"

    rm -rf "$WASI_ADAPTER_DEST"
    mkdir -p "$WASI_ADAPTER_DEST"
    mv "$out" "$file"
    echo "$WASI_ADAPTER_VERSION" > "$WASI_ADAPTER_DEST/VERSION"
    echo "init.sh: wasi adapter $WASI_ADAPTER_VERSION installed at $WASI_ADAPTER_DEST"
}

install_zig
install_wasmtime
install_wasmtime_cli
install_binaryen
install_wabt
install_wasmtools
install_wasi_adapter

echo
echo "Add zig to PATH for this shell:"
echo "    . ./$ZIG_DEST/activate"
echo "or:"
echo "    export PATH=\"\$PWD/$ZIG_DEST:\$PATH\""
