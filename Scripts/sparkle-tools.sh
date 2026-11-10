#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Prints the folder with Sparkle's command line tools (sign_update, generate_keys) of the Sparkle
# release Package.resolved pins, downloaded once from Sparkle's GitHub release into the build
# directory and checked against its SHA-256. The app's Sparkle.framework comes from SwiftPM; these
# tools sign the DMG and the appcast (Scripts/appcast.sh).
#
#   bin="$(Scripts/sparkle-tools.sh)"
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION=2.10.1
SHA256=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27

pinned="$(python3 -c 'import json,sys; print(next(p["state"]["version"] for p in json.load(open(sys.argv[1]))["pins"] if p["identity"] == "sparkle"))' "$ROOT/Package.resolved")"
[ "$pinned" = "$VERSION" ] || { echo "sparkle-tools: Package.resolved pins Sparkle $pinned, this script fetches $VERSION; update both" >&2; exit 1; }

DIR="${ESCLOP_SCRATCH_PATH:-$ROOT/.build}/sparkle-tools-$VERSION"
if [ ! -x "$DIR/bin/sign_update" ]; then
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/sparkle-tools.XXXXXX")"
  trap 'rm -rf "$TMP"' EXIT
  curl -fsSL --retry 3 -o "$TMP/sparkle.tar.xz" "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz"
  got="$(shasum -a 256 "$TMP/sparkle.tar.xz" | cut -d' ' -f1)"
  [ "$got" = "$SHA256" ] || { echo "sparkle-tools: Sparkle-$VERSION.tar.xz has SHA-256 $got, expected $SHA256" >&2; exit 1; }
  mkdir -p "$TMP/x" && tar -xf "$TMP/sparkle.tar.xz" -C "$TMP/x" ./bin ./LICENSE
  rm -rf "$DIR" && mkdir -p "$DIR" && mv "$TMP/x/bin" "$TMP/x/LICENSE" "$DIR/"
fi
echo "$DIR/bin"
