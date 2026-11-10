#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Assembles dist/L'Esclop.app from a release build:
#   Contents/Info.plist          from Scripts/templates/Info.plist.in
#   Contents/MacOS/EsclopApp     the app (universal)
#   Contents/MacOS/esclop        the command line (universal), so the app can install it
#   Contents/Resources/bin/      the bundled tools and esclop-engine, from Binaries/
#   Contents/Resources/LICENSES/ every licence text and notice (Scripts/stage-notices.sh)
#   Contents/Resources/AppIcon.icns from assets/AppIcon.icns (regenerate with `make icons`)
# then signs it (ad hoc, or with $ESCLOP_SIGN_IDENTITY and the hardened runtime), verifies the
# signature and runs the licence gate on the result.
#
#   Scripts/bundle-app.sh
#
# The EsclopApp product only exists when Xcode is installed (see Package.swift); without it the
# script says so and exits 0. Environment: ESCLOP_SOURCE_URL (Info.plist EsclopSourceURL, the
# place the corresponding source is offered; defaults to the origin remote's release page),
# ESCLOP_BUILD_NUMBER (CFBundleVersion; defaults to the commit count).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
APP="dist/L'Esclop.app"
EXEC=EsclopApp

if ! swift package dump-package 2>/dev/null | grep -q "\"$EXEC\""; then
  echo "bundle-app: skipped: this package has no $EXEC product (it is only added when Xcode is installed; see Package.swift)."
  exit 0
fi

for t in esclop-engine ffmpeg ffprobe gs gifsicle; do
  [ -x "Binaries/$t" ] || { echo "bundle-app: Binaries/$t is missing (Scripts/build-tools.sh, Scripts/build-engine.sh)" >&2; exit 1; }
done

VERSION="$(sed -n 's/.*static let string = "\(.*\)".*/\1/p' Sources/EsclopIPC/Protocol.swift)"
BUILD="${ESCLOP_BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
if [ -z "${ESCLOP_SOURCE_URL+x}" ]; then
  remote="$(git remote get-url origin 2>/dev/null || true)"
  case "$remote" in
    git@github.com:*) remote="https://github.com/${remote#git@github.com:}";;
  esac
  ESCLOP_SOURCE_URL="${remote%.git}${remote:+/releases/tag/v$VERSION}"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
Scripts/build-swift.sh "$EXEC" "$APP/Contents/MacOS/$EXEC"
Scripts/build-swift.sh esclop "$APP/Contents/MacOS/esclop"

sed -e "s|@EXECUTABLE@|$EXEC|" -e "s|@VERSION@|$VERSION|" -e "s|@BUILD@|$BUILD|" \
  -e "s|@SOURCE_URL@|$ESCLOP_SOURCE_URL|" Scripts/templates/Info.plist.in > "$APP/Contents/Info.plist"
plutil -lint -s "$APP/Contents/Info.plist"
# The Finder Quick Actions' titles in each language (Info.plist's NSServices hold the English).
for strings in Scripts/templates/ServicesMenu/*.lproj; do
  mkdir -p "$APP/Contents/Resources/$(basename "$strings")"
  cp "$strings/ServicesMenu.strings" "$APP/Contents/Resources/$(basename "$strings")/"
done

printf 'APPL????' > "$APP/Contents/PkgInfo"

for t in esclop-engine ffmpeg ffprobe gs gifsicle; do cp "Binaries/$t" "$APP/Contents/Resources/bin/"; done
Scripts/stage-notices.sh "$APP/Contents/Resources/LICENSES"

# SwiftPM resource bundles (Bundle.module), for the app and its dependencies (KeyboardShortcuts).
# The accessors the Swift Build engine generates look in Bundle.main.resourceURL first, which
# is Contents/Resources. (Nothing may sit in the bundle's root: codesign rejects it.)
bindir="$(swift build -c release --build-system "${ESCLOP_BUILD_SYSTEM:-swiftbuild}" --scratch-path "${ESCLOP_SCRATCH_PATH:-$ROOT/.build}" --triple arm64-apple-macosx14.0 --show-bin-path)"
bundles=0
for b in "$bindir"/*.bundle; do
  [ -d "$b" ] && cp -R "$b" "$APP/Contents/Resources/" && bundles=$((bundles + 1))
done
[ "$bundles" -gt 0 ] || { echo "bundle-app: no resource bundles in $bindir" >&2; exit 1; }
# The older engine's accessor carries the build directory's path to each bundle, and finds the
# bundles nowhere else once the app leaves this machine: refuse to ship it.
if strings -a "$APP/Contents/MacOS/$EXEC" | grep -Eq '/[^/]+\.bundle$' &&
   strings -a "$APP/Contents/MacOS/$EXEC" | grep -Fq 'could not load resource bundle: from'; then
  echo "bundle-app: $EXEC was built with a resource accessor that only looks beside the app bundle and in the build directory; it would die at launch on any other Mac. Build with the Swift Build engine (ESCLOP_BUILD_SYSTEM=swiftbuild, the default here)." >&2
  exit 1
fi

# The app icon is committed (assets/AppIcon.icns, CFBundleIconFile in the template), so bundling
# needs no SVG tools. The menu bar glyph travels in EsclopAppKit's resource bundle, copied above.
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Shortcuts actions: the App Intents metadata Xcode would write, from the release build.
Scripts/appintents-metadata.sh "$APP"


# Sign inside out: nested executables first, then the bundle.
if [ -n "${ESCLOP_SIGN_IDENTITY:-}" ]; then
  sign=(codesign --force --options runtime --timestamp --sign "$ESCLOP_SIGN_IDENTITY")
else
  sign=(codesign --force --sign -)
fi
for f in "$APP"/Contents/Resources/bin/* "$APP/Contents/MacOS/esclop"; do "${sign[@]}" "$f" >/dev/null; done
"${sign[@]}" "$APP" >/dev/null
codesign --verify --deep --strict "$APP"

Scripts/licence-gate.sh --dist --universal "$APP"
echo "bundle-app: $APP"
echo "  version   $VERSION ($BUILD), dev.esclop.app, macOS 14.0+"
echo "  size      $(du -sh "$APP" | cut -f1)"
echo "  signature $(codesign -dv "$APP" 2>&1 | sed -n 's/^Signature=//p; s/^Authority=//p' | head -1)"
echo "  source    ${ESCLOP_SOURCE_URL:-none}"
