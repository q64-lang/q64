#!/usr/bin/env bash
# init.sh — set up the dev environment for the `qube` binary.
#
# Unlike the repo-root ../init.sh (which also installs the wasmtime C API and
# Binaryen for q64/ and the runtime adapters), `qube` is pure Zig with no
# external C libraries, so this only pins and installs the Zig toolchain into
# vendor/zig/.
#
# Re-runnable; skips work that's already done. Run from this directory:
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
# Then:  zig build  (and  zig build cli-tests  to run the black-box suite,
# which additionally needs `bun` on PATH).
#
# Pinned version can be overridden via env:
#
#     ZIG_VERSION=0.14.1 ./init.sh

set -euo pipefail

ZIG_VERSION="${ZIG_VERSION:-0.16.0}"
ZIG_DEST="vendor/zig"
ZIG_INDEX_URL="https://ziglang.org/download/index.json"

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

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# --- Zig ---------------------------------------------------------------

if [ -x "$ZIG_DEST/zig" ]; then
    installed_version="$("$ZIG_DEST/zig" version 2>/dev/null || echo unknown)"
    if [ "$installed_version" = "$ZIG_VERSION" ]; then
        echo "init.sh: zig $ZIG_VERSION already installed at $ZIG_DEST"
        exit 0
    fi
    echo "init.sh: replacing existing zig $installed_version with $ZIG_VERSION"
fi

# Pull the tarball URL and SHA-256 from ziglang.org's release index so we don't
# have to hand-pin per-platform hashes that would go stale. The HTTPS
# connection to ziglang.org is the trust root.
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
# Source from this directory's parent to add the pinned zig to PATH:
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
echo
echo "Add zig to PATH for this shell:"
echo "    . ./$ZIG_DEST/activate"
echo "or:"
echo "    export PATH=\"\$PWD/$ZIG_DEST:\$PATH\""
echo
echo "Then build with:  zig build"
if ! command -v bun >/dev/null 2>&1; then
    echo "Note: 'bun' is not on PATH; 'zig build cli-tests' needs it (https://bun.sh)."
fi
