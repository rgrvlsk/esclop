#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds the release disk image: the app on the left, an Applications link on the right, the
# background from assets/dmg (Scripts/dmg-background.swift draws it) and the app icon on the
# volume, in a 660 × 400 window with no toolbar, sidebar, path bar or status bar.
#
#   Scripts/make-dmg.sh APP OUT.dmg
#
# dmgbuild writes the window layout into .DS_Store directly, so no Finder, no Apple events and
# no automation permission are needed (Finder scripting times out or asks for consent on an
# unattended Mac). It is pinned with hashes and installed into a throwaway venv for this build
# only. The result is ULFO (lzfse) on HFS+: on an APFS volume Finder on macOS 26.6 keeps the
# layout but shows no background. The script checks its own output: the app's signature (so APP
# must be signed, ad hoc at least), the Applications link, the hidden background, the HFS+
# volume, a .DS_Store that names the background and the volume icon flag.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP=${1:?usage: Scripts/make-dmg.sh APP OUT.dmg}
OUT=${2:?usage: Scripts/make-dmg.sh APP OUT.dmg}
app_name="$(basename "$APP")"
[ -d "$APP" ] || { echo "make-dmg: no app at $APP" >&2; exit 1; }

work="$(mktemp -d)"
mounted=""
cleanup() {
  [ -z "$mounted" ] || hdiutil detach -quiet -force "$mounted" || true
  rm -rf "$work"
}
trap cleanup EXIT

# dmgbuild 1.6.5 and its two dependencies, pure-Python wheels; hashes as PyPI lists them.
cat > "$work/requirements.txt" <<'EOF'
dmgbuild==1.6.5 --hash=sha256:e19ab8c5e8238e6455d9ccb9175817be7fd62b9cdd1eef20f63dd88e0ec469ab
ds_store==1.3.1 --hash=sha256:fbacbb0bd5193ab3e66e5a47fff63619f15e374ffbec8ae29744251a6c8f05b5
mac_alias==2.2.2 --hash=sha256:504ab8ac546f35bbd75ad014d6ad977c426660aa721f2cd3acf3dc2f664141bd
EOF
python3 -m venv "$work/venv"
"$work/venv/bin/python" -m pip install --quiet --disable-pip-version-check --no-deps \
  --only-binary :all: --require-hashes -r "$work/requirements.txt"

# Icon positions are their centres, matching Scripts/dmg-background.swift. The window rect is
# the frame, bottom-left origin: 660 × 400 of content under a 28 pt title bar.
# dmgbuild stores the background twice, as an alias and as a bookmark (pBBk); Finder on macOS 26
# fails on the bookmark and then shows no background at all, so the bookmark is left out.
mkdir -p "$(dirname "$OUT")"
"$work/venv/bin/python" -I - "$APP" "$ROOT" "$OUT" <<'EOF'
import os, sys
import dmgbuild.core as core
app, root, out = sys.argv[1:]
core.Bookmark = type("NoBookmark", (), {"for_file": staticmethod(lambda path: None)})
core.build_dmg(out, "L'Esclop", settings={
    "format": "ULFO",
    "filesystem": "HFS+",
    "files": [app],
    "symlinks": {"Applications": "/Applications"},
    "icon": os.path.join(root, "assets/AppIcon.icns"),
    "background": os.path.join(root, "assets/dmg/background.png"),
    "window_rect": ((390, 236), (660, 428)),
    "icon_size": 128,
    "text_size": 13,
    "icon_locations": {os.path.basename(app): (165, 170), "Applications": (495, 170)},
})
EOF

# Check what is shipped, read-only and hidden from Finder.
check="$work/check"
mkdir -p "$check"
hdiutil attach -quiet -nobrowse -readonly -noverify -mountpoint "$check" "$OUT"
mounted="$check"
fail() { echo "make-dmg: $OUT $1" >&2; exit 1; }
# dmgbuild ignores a failed copy of the app; a partial copy breaks the app's signature seal.
codesign --verify --deep --strict "$check/$app_name" || fail "has a damaged $app_name"
[ "$(readlink "$check/Applications")" = /Applications ] || fail "has no Applications link"
[ -s "$check/.background.tiff" ] || fail "has no background"
diskutil info "$check" | grep -q 'Personality: *HFS+' || fail "is not HFS+, so Finder 26 hides the background"
[ -s "$check/.VolumeIcon.icns" ] || fail "has no volume icon"
LC_ALL=C grep -aq 'backgroundImageAlias' "$check/.DS_Store" || fail "has a .DS_Store without the background"
! LC_ALL=C grep -aq 'pBBk' "$check/.DS_Store" || fail "has a background bookmark that Finder 26 rejects"
# kHasCustomIcon (0x0400) in the root folder's Finder flags makes Finder use .VolumeIcon.icns.
flags_high="$(xattr -px com.apple.FinderInfo "$check" 2>/dev/null | tr -d ' \n' | cut -c17-18 || true)"
(( 0x${flags_high:-00} & 0x04 )) || fail "has no custom volume icon flag"
visible="$(cd "$check" && ls -1 | tr '\n' ' ')"
[ "$visible" = "Applications $app_name " ] || fail "shows more than the app and Applications: $visible"
hdiutil detach -quiet "$check"
mounted=""
echo "make-dmg: wrote $OUT"
