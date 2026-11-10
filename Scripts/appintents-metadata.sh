#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Writes Contents/Resources/Metadata.appintents into a bundled app, the step Xcode runs for App
# Intents: Shortcuts reads the actions from it. A SwiftPM build does not run it, but the Swift
# Build engine emits the compiler's constant values (*.swiftconstvalues), which is what Xcode's
# appintentsmetadataprocessor needs. The intents live in EsclopAppKit, a static library of the
# app, so its metadata is made first and passed to the app module's as a static dependency.
#
#   Scripts/appintents-metadata.sh "dist/L'Esclop.app"
#
# Needs a release build of the app in ESCLOP_SCRATCH_PATH (default .build) and Xcode's toolchain.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP=${1:?usage: Scripts/appintents-metadata.sh APP}
cd "$ROOT"
SCRATCH="${ESCLOP_SCRATCH_PATH:-$ROOT/.build}"
RELEASE="$SCRATCH/out/Intermediates.noindex/esclop.build/Release"
TOOLCHAIN="$(dirname "$(dirname "$(dirname "$(xcrun --find swift)")")")"
PROCESSOR="$TOOLCHAIN/usr/bin/appintentsmetadataprocessor"
[ -x "$PROCESSOR" ] || { echo "appintents-metadata: $PROCESSOR is missing (it comes with Xcode)" >&2; exit 1; }
SDK="$(xcrun --sdk macosx --show-sdk-path)"
XCODE_BUILD="$(xcodebuild -version | awk '/Build version/ {print $3}')"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/appintents.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

process() { # module, output folder, [static metadata list]
  local module=$1 out=$2 statics=${3:-}
  find "$ROOT/Sources/$module" -name '*.swift' > "$TMP/$module.sources"
  find "$RELEASE/$module"-*.build/Objects-normal/arm64 -name '*.swiftconstvalues' > "$TMP/$module.consts" 2>/dev/null || true
  [ -s "$TMP/$module.consts" ] || { echo "appintents-metadata: no constant values for $module in $RELEASE (build it first)" >&2; exit 1; }
  mkdir -p "$out"
  "$PROCESSOR" --output "$out" --toolchain-dir "$TOOLCHAIN" --module-name "$module" --sdk-root "$SDK" \
    --xcode-version "$XCODE_BUILD" --platform-family macOS --deployment-target 14.0 --target-triple arm64-apple-macosx14.0 \
    --source-file-list "$TMP/$module.sources" --swift-const-vals-list "$TMP/$module.consts" \
    ${statics:+--static-metadata-file-list "$statics"} --force --quiet-warnings > "$TMP/$module.log" 2>&1 ||
    { cat "$TMP/$module.log" >&2; exit 1; }
}

process EsclopAppKit "$TMP/kit"
echo "$TMP/kit/Metadata.appintents/extract.actionsdata" > "$TMP/statics"
process EsclopApp "$TMP/app" "$TMP/statics"
rm -rf "$APP/Contents/Resources/Metadata.appintents"
cp -R "$TMP/app/Metadata.appintents" "$APP/Contents/Resources/"
# The actions' titles in Catalan: App Intents look them up in the app's own Localizable.strings
# (the main bundle), so the catalog's Catalan goes there too.
mkdir -p "$APP/Contents/Resources/ca.lproj"
python3 - "$ROOT/Sources/EsclopAppKit/Resources/Localizable.xcstrings" "$APP/Contents/Resources/ca.lproj/Localizable.strings" <<'PY'
import json, plistlib, sys
strings = json.load(open(sys.argv[1]))["strings"]
table = {k: v["localizations"]["ca"]["stringUnit"]["value"] for k, v in strings.items() if "ca" in v.get("localizations", {})}
plistlib.dump(table, open(sys.argv[2], "wb"), fmt=plistlib.FMT_BINARY)
PY
actions="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["actions"]))' "$APP/Contents/Resources/Metadata.appintents/extract.actionsdata")"
[ "$actions" -gt 0 ] || { echo "appintents-metadata: no actions in the metadata" >&2; exit 1; }
echo "appintents-metadata: $actions Shortcuts actions"
