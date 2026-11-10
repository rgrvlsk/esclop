#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Builds a SwiftPM product in release mode for arm64 and x86_64 (macOS 14) and merges the two
# slices with lipo, then strips local symbols and signs ad hoc.
#
#   Scripts/build-swift.sh PRODUCT OUTFILE
#
# Each architecture is built with `--triple`, which works with the Command Line Tools alone as
# well as with Xcode (`--arch arm64 --arch x86_64` needs Xcode's build system).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRODUCT=${1:?usage: Scripts/build-swift.sh PRODUCT OUTFILE}
OUT=${2:?usage: Scripts/build-swift.sh PRODUCT OUTFILE}
cd "$ROOT"
# Where SwiftPM builds. Some SwiftPM versions write this directory into the binary (the
# fallback path of each resource bundle accessor), so a release sets ESCLOP_SCRATCH_PATH to a
# directory outside any home.
SCRATCH="${ESCLOP_SCRATCH_PATH:-$ROOT/.build}"
# Always the Swift Build engine. SwiftPM's older engine (the default before Swift 6.4) writes a
# `Bundle.module` that looks for resource bundles beside the app bundle and in the build
# directory only, never in Contents/Resources, so an app built with it dies at launch anywhere
# but on the machine that built it.
BUILD_SYSTEM="${ESCLOP_BUILD_SYSTEM:-swiftbuild}"

# Each slice is copied out as soon as it is built: some SwiftPM versions give every triple the
# same output directory, so the next build would overwrite it.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/build-swift.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
slices=()
for arch in arm64 x86_64; do
  triple="$arch-apple-macosx14.0"
  echo "build-swift: $PRODUCT for $triple" >&2
  swift build -c release --build-system "$BUILD_SYSTEM" --scratch-path "$SCRATCH" --product "$PRODUCT" --triple "$triple" >&2
  cp "$(swift build -c release --build-system "$BUILD_SYSTEM" --scratch-path "$SCRATCH" --triple "$triple" --show-bin-path)/$PRODUCT" "$TMP/$arch"
  [ "$(lipo -archs "$TMP/$arch")" = "$arch" ] || { echo "build-swift: the $triple build is not $arch" >&2; exit 1; }
  slices+=("$TMP/$arch")
done
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
lipo -create "${slices[@]}" -output "$OUT"
strip -x "$OUT"
codesign --force --sign - "$OUT" >/dev/null 2>&1
echo "build-swift: $(lipo -archs "$OUT") -> $OUT" >&2
