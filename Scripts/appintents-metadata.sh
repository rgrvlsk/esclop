#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Writes Contents/Resources/Metadata.appintents into a bundled app, the step Xcode runs for App
# Intents: Shortcuts reads the actions from it. A SwiftPM build does not run it. Xcode's
# appintentsmetadataprocessor needs the compiler's constant values (*.swiftconstvalues) for the
# intents, and only some Swift Build versions write them in a SwiftPM build (Xcode 27 does,
# Xcode 26 does not), so this script asks the compiler for them itself: a type check of each
# file that imports AppIntents, against the modules of the release build. The intents live in
# EsclopAppKit, a static library of the app, so its metadata is made first and passed to the
# app module's as a static dependency.
#
#   Scripts/appintents-metadata.sh "dist/L'Esclop.app"
#
# Needs a release build of the app in ESCLOP_SCRATCH_PATH (default .build) and Xcode's toolchain.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP=${1:?usage: Scripts/appintents-metadata.sh APP}
cd "$ROOT"
SCRATCH="${ESCLOP_SCRATCH_PATH:-$ROOT/.build}"
OUT="$SCRATCH/out"
RELEASE="$OUT/Intermediates.noindex/esclop.build/Release"
PRODUCTS="$OUT/Products/Release"
[ -d "$PRODUCTS" ] && [ -d "$RELEASE" ] || {
  echo "appintents-metadata: no release build of the app in $OUT (build it first)" >&2; exit 1; }
TOOLCHAIN="$(dirname "$(dirname "$(dirname "$(xcrun --find swift)")")")"
PROCESSOR="$TOOLCHAIN/usr/bin/appintentsmetadataprocessor"
[ -x "$PROCESSOR" ] || { echo "appintents-metadata: $PROCESSOR is missing (it comes with Xcode)" >&2; exit 1; }
SDK="$(xcrun --sdk macosx --show-sdk-path)"
XCODE_BUILD="$(xcodebuild -version | awk '/Build version/ {print $3}')"
TARGET=arm64-apple-macosx14.0
TMP="$(mktemp -d "${TMPDIR:-/tmp}/appintents.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
# The protocols whose conformances the compiler records, as Xcode 27 lists them.
cat > "$TMP/protocols.json" <<'JSON'
["AnyResolverProviding","AppEntity","AppEnum","AppExtension","AppIntent","AppIntentsPackage","AppShortcutProviding","AppShortcutsProvider","AppUnionValue","AppUnionValueCasesProviding","DynamicMigration_v1","DynamicOptionsProvider","EntityQuery","ExtensionPointDefining","IntentValueQuery","Resolver","StaticMigration_v1","TransientEntity","_AssistantIntentsProvider","_GenerativeFunctionExtractable","_IntentValueRepresentable"]
JSON
modulemaps=()
for m in "$OUT"/Intermediates.noindex/GeneratedModuleMaps/*.modulemap; do
  [ -f "$m" ] && modulemaps+=(-Xcc "-fmodule-map-file=$m")
done

process() { # module, output folder, [static metadata list]
  local module=$1 out=$2 statics=${3:-} file others s n=0
  # The module's sources as the build compiled them, with the ones it generated (Bundle.module).
  { find "$ROOT/Sources/$module" -name '*.swift'
    find "$RELEASE/$module"-*.build/DerivedSources -name '*.swift' 2>/dev/null || true; } > "$TMP/$module.sources"
  : > "$TMP/$module.consts"
  while IFS= read -r file; do
    grep -q '^import AppIntents' "$file" || [ "$module" = EsclopApp ] || continue
    n=$((n + 1))
    others=()
    while IFS= read -r s; do [ "$s" = "$file" ] || others+=("$s"); done < "$TMP/$module.sources"
    xcrun swift-frontend -typecheck -primary-file "$file" ${others[@]+"${others[@]}"} \
      -module-name "$module" -package-name esclop -parse-as-library -swift-version 5 \
      -enable-experimental-feature StrictConcurrency -target "$TARGET" -sdk "$SDK" -I "$PRODUCTS" \
      ${modulemaps[@]+"${modulemaps[@]}"} -plugin-path "$TOOLCHAIN/usr/lib/swift/host/plugins" \
      -plugin-path "$TOOLCHAIN/usr/local/lib/swift/host/plugins" \
      -const-gather-protocols-file "$TMP/protocols.json" \
      -emit-const-values-path "$TMP/$module-$n.swiftconstvalues" > "$TMP/$module-$n.log" 2>&1 ||
      { echo "appintents-metadata: the type check of $file failed:" >&2; grep -m 20 'error:' "$TMP/$module-$n.log" >&2; exit 1; }
    echo "$TMP/$module-$n.swiftconstvalues" >> "$TMP/$module.consts"
  done < "$TMP/$module.sources"
  [ -s "$TMP/$module.consts" ] || { echo "appintents-metadata: no source files for $module" >&2; exit 1; }
  mkdir -p "$out"
  "$PROCESSOR" --output "$out" --toolchain-dir "$TOOLCHAIN" --module-name "$module" --sdk-root "$SDK" \
    --xcode-version "$XCODE_BUILD" --platform-family macOS --deployment-target 14.0 --target-triple "$TARGET" \
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
