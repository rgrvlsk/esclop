#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Fills a LICENSES/ directory for something we distribute (the .app, the CLI tarball):
#   <tool>.txt          licence texts of the bundled tools, from Binaries/LICENSES/
#   esclop.txt          L'Esclop's own licence (LICENSE)
#   esclop-engine.md    the crates linked into esclop-engine (engine/THIRD_PARTY-engine.md)
#   swift-packages.md   the Swift packages linked into the CLI and the app (Scripts/swift-notices.sh)
#   THIRD_PARTY.md      the record of the bundled tools
# Scripts/licence-gate.sh --dist checks the result.
#
#   Scripts/stage-notices.sh DEST
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST=${1:?usage: Scripts/stage-notices.sh DEST}
ls "$ROOT"/Binaries/LICENSES/*.txt >/dev/null 2>&1 ||
  { echo "stage-notices: Binaries/LICENSES/ is empty (run Scripts/build-tools.sh)" >&2; exit 1; }
mkdir -p "$DEST"
cp "$ROOT"/Binaries/LICENSES/*.txt "$DEST/"
cp "$ROOT/LICENSE" "$DEST/esclop.txt"
cp "$ROOT/engine/THIRD_PARTY-engine.md" "$DEST/esclop-engine.md"
cp "$ROOT/THIRD_PARTY.md" "$DEST/THIRD_PARTY.md"
"$ROOT/Scripts/swift-notices.sh" "$DEST/swift-packages.md"
