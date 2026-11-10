#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Starts a bundled app the way another Mac would: from a copy in a temporary folder, with the
# build directory moved out of the way, so nothing it needs can come from the checkout. Fails
# when the app does not stay up, when the command line inside it does not see it, or when a
# picture does not go through its engine.
#
#   Scripts/smoke-app.sh "dist/L'Esclop.app"
#
# For CI. It runs the real app as the current user: the app watches the clipboard and writes
# its settings, so outside CI it only runs with ESCLOP_SMOKE_HERE=1.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP=${1:?usage: Scripts/smoke-app.sh APP}
[ -d "$APP" ] || { echo "smoke-app: $APP is not an app bundle" >&2; exit 1; }
if [ "${CI:-}" != true ] && [ "${ESCLOP_SMOKE_HERE:-}" != 1 ]; then
  echo "smoke-app: this starts the real app as you; set ESCLOP_SMOKE_HERE=1 to do that outside CI" >&2
  exit 2
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/smoke-app.XXXXXX")"
copy="$TMP/L'Esclop.app"
ditto "$APP" "$copy"
scratch="${ESCLOP_SCRATCH_PATH:-$ROOT/.build}"
hidden=""
pid=""
cleanup() {
  [ -n "$pid" ] && kill "$pid" 2>/dev/null
  [ -n "$hidden" ] && mv "$hidden" "$scratch"
  rm -rf "$TMP"
}
trap cleanup EXIT
if [ -d "$scratch" ]; then
  hidden="$scratch.smoke-$$"
  mv "$scratch" "$hidden"
fi

"$copy/Contents/MacOS/EsclopApp" > "$TMP/app.log" 2>&1 &
pid=$!
for second in $(seq 1 15); do
  sleep 1
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "smoke-app: the app exited after ${second} s" >&2
    tail -20 "$TMP/app.log" >&2
    pid=""
    exit 1
  fi
done

cli="$copy/Contents/MacOS/esclop"
status="$("$cli" status 2>&1 || true)"
if ! grep -Eq '^app +running' <<<"$status"; then
  echo "smoke-app: the command line does not see the running app" >&2
  echo "$status" >&2
  exit 1
fi

cp "$ROOT/assets/icon-wood.png" "$TMP/sample.png"
before="$(stat -f %z "$TMP/sample.png")"
if ! "$cli" optimise "$TMP/sample.png" > "$TMP/cli.log" 2>&1; then
  echo "smoke-app: optimising a PNG through the app failed" >&2
  cat "$TMP/cli.log" >&2
  exit 1
fi
kill -0 "$pid" 2>/dev/null || { echo "smoke-app: the app died while optimising" >&2; tail -20 "$TMP/app.log" >&2; pid=""; exit 1; }
# Shortcuts reads the actions from the App Intents metadata the bundle carries.
metadata="$copy/Contents/Resources/Metadata.appintents/extract.actionsdata"
actions="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["actions"]))' "$metadata" 2>/dev/null || echo 0)"
if [ "$actions" -lt 8 ] || [ ! -f "$copy/Contents/Resources/ca.lproj/Localizable.strings" ]; then
  echo "smoke-app: the bundle carries $actions Shortcuts actions (8 expected) or lacks their Catalan" >&2
  exit 1
fi
# Updates: Sparkle with its helpers and XPC services, validly signed, and the feed and key.
fw="$copy/Contents/Frameworks/Sparkle.framework/Versions/B"
for part in "$fw/Autoupdate" "$fw/Updater.app" "$fw/XPCServices/Installer.xpc" "$fw/XPCServices/Downloader.xpc" "$copy/Contents/Frameworks/Sparkle.framework"; do
  codesign --verify --strict "$part" 2>/dev/null || { echo "smoke-app: ${part#"$copy/"} is missing or not validly signed" >&2; exit 1; }
done
for key in SUFeedURL SUPublicEDKey; do
  [ -n "$(plutil -extract "$key" raw -o - "$copy/Contents/Info.plist" 2>/dev/null)" ] || { echo "smoke-app: Info.plist has no $key" >&2; exit 1; }
done
echo "smoke-app: up for 15 s, seen by the command line, PNG $before -> $(stat -f %z "$TMP/sample.png") bytes, $actions Shortcuts actions, Sparkle signed"

