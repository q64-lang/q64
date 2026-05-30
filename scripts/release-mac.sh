#!/usr/bin/env bash
# release-mac.sh — build the macOS q64 + qube binaries and attach them to a
# GitHub release.
#
# CI (.github/workflows/release.yml) builds linux-amd64 only — there are no
# hosted macOS/arm runners. macOS binaries are built on a Mac (q64 links a
# host-built Binaryen static lib, so it can't be cross-compiled from linux) and
# uploaded to the release this script targets.
#
# Usage:
#   scripts/release-mac.sh [TAG]      # TAG defaults to "nightly"
#
# Builds for the host architecture only (arm64 on Apple Silicon, amd64 on
# Intel). Run it once on each Mac arch you want to publish.
#
# Prereqs: ./init.sh has vendored the toolchain (vendor/zig, vendor/binaryen);
# `gh` is installed and authenticated for the q64-lang/q64 repo.
set -euo pipefail

cd "$(dirname "$0")/.."   # repo root

TAG="${1:-nightly}"

case "$(uname -s)" in
  Darwin) ;;
  *) echo "release-mac.sh: must run on macOS (got $(uname -s))" >&2; exit 1 ;;
esac

case "$(uname -m)" in
  arm64)  ARCH=arm64 ;;
  x86_64) ARCH=amd64 ;;
  *) echo "release-mac.sh: unsupported arch $(uname -m)" >&2; exit 1 ;;
esac
PLAT="darwin-${ARCH}"

ZIG="vendor/zig/zig"
if [ ! -x "$ZIG" ]; then
  echo "release-mac.sh: $ZIG not found — run ./init.sh first" >&2
  exit 1
fi

echo "release-mac.sh: building q64 + qube (ReleaseFast) for ${PLAT}"
( cd q64  && "../${ZIG}" build -Doptimize=ReleaseFast )
( cd qube && "../${ZIG}" build -Doptimize=ReleaseFast )

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
cp q64/zig-out/bin/q64   "${OUT}/q64-${PLAT}"
cp qube/zig-out/bin/qube "${OUT}/qube-${PLAT}"
( cd "$OUT" && shasum -a 256 "q64-${PLAT}" "qube-${PLAT}" > "SHA256SUMS-${PLAT}" )

echo "release-mac.sh: built"
ls -la "$OUT"
cat "${OUT}/SHA256SUMS-${PLAT}"

if ! command -v gh >/dev/null 2>&1; then
  echo "release-mac.sh: gh not installed — binaries are in $OUT (copy them out before this script exits)." >&2
  echo "  Then upload with: gh release upload ${TAG} <files> --clobber" >&2
  trap - EXIT   # keep $OUT so the user can grab the files
  exit 1
fi

if ! gh release view "$TAG" >/dev/null 2>&1; then
  echo "release-mac.sh: release '${TAG}' not found. Push to main to let CI cut it first," >&2
  echo "  or create it, then re-run. Binaries are in $OUT." >&2
  trap - EXIT
  exit 1
fi

echo "release-mac.sh: uploading to release ${TAG}"
gh release upload "$TAG" \
  "${OUT}/q64-${PLAT}" \
  "${OUT}/qube-${PLAT}" \
  "${OUT}/SHA256SUMS-${PLAT}" \
  --clobber

echo "release-mac.sh: done — ${PLAT} binaries attached to ${TAG}."
