#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Regenerates the app icon and vector menu bar resource from assets/.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

for tool in rsvg-convert sips iconutil; do
  command -v "$tool" >/dev/null || { echo "build-icons: $tool is required (rsvg-convert comes from librsvg)." >&2; exit 1; }
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
iconset="$work/AppIcon.iconset"
mkdir -p "$iconset"
rsvg-convert --width 1024 --height 1024 --output assets/AppIcon.png assets/icon.svg
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" assets/AppIcon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
  retina=$((size * 2))
  sips -z "$retina" "$retina" assets/AppIcon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil --convert icns --output assets/AppIcon.icns "$iconset"
rsvg-convert --format pdf --output Sources/EsclopAppKit/Resources/MenuBarIcon.pdf assets/menubar.svg
echo "build-icons: generated AppIcon.png, AppIcon.icns and MenuBarIcon.pdf."
