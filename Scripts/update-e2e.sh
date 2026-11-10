#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Proves that an installed L'Esclop updates itself. From one bundled app it makes version N
# (build 1) and version N+1 (build 2), both with a throwaway EdDSA key, a DMG of N+1 and a signed
# appcast for it, served on 127.0.0.1. It installs N in a folder of its own, turns on automatic
# installation, starts N with ESCLOP_UPDATE_FEED pointing at the local feed, waits until Sparkle
# has downloaded N+1 and started its installer, ends N, and waits until the bundle on disk is N+1,
# still validly signed, and starts.
#
#   Scripts/update-e2e.sh "dist/L'Esclop.app"
#
# It runs the real app as the current user and changes two settings (they are reset at the
# end), so outside CI it only runs with ESCLOP_SMOKE_HERE=1. Writes what it saw to
# $ESCLOP_E2E_OUT/result.txt when that is set.
#
# ESCLOP_E2E_INTERACTIVE=1 is the same with automatic installation off: Sparkle's window offers
# N+1 with its notes, and the script waits up to five minutes for a person to click "Install
# Update", then for Sparkle to put N+1 in place and start it again.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP=${1:?usage: Scripts/update-e2e.sh APP}
[ -d "$APP" ] || { echo "update-e2e: $APP is not an app bundle" >&2; exit 1; }
if [ "${CI:-}" != true ] && [ "${ESCLOP_SMOKE_HERE:-}" != 1 ]; then
  echo "update-e2e: this starts the real app as you; set ESCLOP_SMOKE_HERE=1 to do that outside CI" >&2
  exit 2
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/update-e2e.XXXXXX")"
installed="$TMP/Applications/L'Esclop.app"
next="$TMP/next/L'Esclop.app"
feed="$TMP/feed"
pid=""; server=""; cli=""
say() { echo "update-e2e: $*"; [ -z "${ESCLOP_E2E_OUT:-}" ] || echo "$*" >> "$ESCLOP_E2E_OUT/result.txt"; }
cleanup() {
  [ -n "$pid" ] && kill "$pid" 2>/dev/null
  [ -n "$server" ] && kill "$server" 2>/dev/null
  if [ -n "$cli" ]; then
    "$cli" settings reset installUpdatesAutomatically > /dev/null 2>&1 || true
    "$cli" settings reset checkForUpdatesAutomatically > /dev/null 2>&1 || true
  fi
  pkill -f "$TMP/" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT
[ -z "${ESCLOP_E2E_OUT:-}" ] || { mkdir -p "$ESCLOP_E2E_OUT"; : > "$ESCLOP_E2E_OUT/result.txt"; }

# A throwaway key: the release key never signs a test build.
keys="$(swift "$ROOT/Scripts/test-signing-key.swift")"
private_key="$(sed -n 1p <<<"$keys")"
public_key="$(sed -n 2p <<<"$keys")"

version() { # app build short-version
  local plist="$1/Contents/Info.plist"
  plutil -replace CFBundleVersion -string "$2" "$plist"
  plutil -replace CFBundleShortVersionString -string "$3" "$plist"
  plutil -replace SUPublicEDKey -string "$public_key" "$plist"
  # Only Info.plist changed: re-seal the bundle; its nested code keeps its signatures.
  codesign --force --sign - "$1" 2> /dev/null
  codesign --verify --deep --strict "$1"
}
mkdir -p "$TMP/Applications" "$TMP/next" "$feed"
ditto "$APP" "$installed"
ditto "$APP" "$next"
version "$installed" 1 1.0.0
version "$next" 2 1.0.1

port="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
hdiutil create -quiet -volname "L'Esclop" -srcfolder "$next" -fs APFS -format ULFO -ov "$feed/next.dmg"
printf '### Added\n- The end-to-end test update.\n' > "$TMP/notes.md"
SPARKLE_ED_PRIVATE_KEY="$private_key" ESCLOP_APPCAST_NOTES="$TMP/notes.md" \
  "$ROOT/Scripts/appcast.sh" "$feed/next.dmg" "http://127.0.0.1:$port/next.dmg" "$feed/appcast.xml"
unset private_key
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$feed" > "$TMP/server.log" 2>&1 &
server=$!

# Automatic installation on, and no record of an earlier check, so Sparkle checks at launch.
cli="$installed/Contents/MacOS/esclop"
"$cli" settings set checkForUpdatesAutomatically true > /dev/null
interactive="${ESCLOP_E2E_INTERACTIVE:-0}"
if [ "$interactive" = 1 ]; then
  "$cli" settings set installUpdatesAutomatically false > /dev/null
else
  "$cli" settings set installUpdatesAutomatically true > /dev/null
fi
defaults delete dev.esclop.app SULastCheckTime > /dev/null 2>&1 || true

ESCLOP_UPDATE_FEED="http://127.0.0.1:$port/appcast.xml" "$installed/Contents/MacOS/EsclopApp" > "$TMP/app.log" 2>&1 &
pid=$!
say "N is build 1 (1.0.0) at $installed, feed on 127.0.0.1:$port"

wait_for() { # seconds description command...
  local limit=$1 what=$2; shift 2
  for _ in $(seq 1 "$limit"); do
    if "$@"; then return 0; fi
    kill -0 "$pid" 2>/dev/null || { say "the app exited while waiting for $what"; tail -20 "$TMP/app.log" >&2; pid=""; return 1; }
    sleep 1
  done
  say "gave up after ${limit} s waiting for $what"
  echo "--- server log" >&2; cat "$TMP/server.log" >&2
  echo "--- app log" >&2; tail -20 "$TMP/app.log" >&2
  echo "--- Sparkle's log" >&2
  log show --last 3m --style compact --predicate 'subsystem == "org.sparkle-project.Sparkle" OR process == "Autoupdate" OR process == "EsclopApp"' 2>/dev/null | tail -40 >&2 || true
  return 1
}
fetched() { grep -q 'GET /next.dmg' "$TMP/server.log"; }
updated() { [ "$(plutil -extract CFBundleVersion raw -o - "$installed/Contents/Info.plist" 2>/dev/null)" = 2 ]; }
if [ "$interactive" = 1 ]; then
  appcast_read() { grep -q 'GET /appcast.xml' "$TMP/server.log"; }
  wait_for 90 "the appcast to be read" appcast_read
  say "Sparkle's window should offer L'Esclop 1.0.1 with its notes: click Install Update (5 min)"
  for _ in $(seq 1 300); do updated && break; sleep 1; done
  updated || { say "the app on disk is still build 1 after five minutes"; exit 1; }
  pid=""
  codesign --verify --deep --strict "$installed"
  say "the app on disk is now build 2, signature valid, quarantine: $(xattr -p com.apple.quarantine "$installed" 2>/dev/null || echo none)"
  relaunched() { pgrep -f "$TMP/Applications/L'Esclop.app/Contents/MacOS/EsclopApp" > /dev/null; }
  for _ in $(seq 1 20); do relaunched && break; sleep 1; done
  if relaunched; then say "Sparkle started N+1 again: N updated itself to N+1"; else say "N+1 is in place but Sparkle did not start it again"; exit 1; fi
  exit 0
fi
installer() { pgrep -f "$TMP/Applications/L'Esclop.app/Contents/Frameworks/Sparkle.framework" > /dev/null || pgrep -x Autoupdate > /dev/null; }
wait_for 90 "the appcast and the DMG to be fetched" fetched
say "N fetched the appcast and the N+1 DMG"
wait_for 60 "Sparkle's installer" installer
sleep 3
say "Sparkle's installer is waiting for N to quit"

kill -TERM "$pid"
for _ in $(seq 1 10); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
kill -0 "$pid" 2>/dev/null && kill -KILL "$pid"
pid=""

for _ in $(seq 1 90); do updated && break; sleep 1; done
if ! updated; then
  say "the app on disk is still build $(plutil -extract CFBundleVersion raw -o - "$installed/Contents/Info.plist" 2>/dev/null || echo '?')"
  log show --last 3m --style compact --predicate 'subsystem == "org.sparkle-project.Sparkle" OR process == "Autoupdate"' 2>/dev/null | tail -40 >&2 || true
  exit 1
fi
codesign --verify --deep --strict "$installed"
quarantine="$(xattr -p com.apple.quarantine "$installed" 2>/dev/null || echo none)"
say "the app on disk is now build 2 ($(plutil -extract CFBundleShortVersionString raw -o - "$installed/Contents/Info.plist")), signature valid, quarantine: $quarantine"

"$installed/Contents/MacOS/EsclopApp" > "$TMP/app2.log" 2>&1 &
pid=$!
sleep 8
kill -0 "$pid" 2>/dev/null || { say "N+1 did not stay up"; tail -20 "$TMP/app2.log" >&2; pid=""; exit 1; }
say "N+1 starts: N updated itself to N+1"
