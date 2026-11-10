#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Writes the Sparkle appcast for one DMG: an item with the version and build read from the app
# inside it, the DMG's size and EdDSA signature, the minimum macOS, and the CHANGELOG.md section
# of that version as Markdown release notes. Then the feed itself is signed (the app sets
# SURequireSignedFeed), so nothing in it can be changed without the key.
#
#   Scripts/appcast.sh DMG URL OUT
#
# URL is where the app downloads the DMG from. The private key is read from the environment
# (SPARKLE_ED_PRIVATE_KEY, base64, as `generate_keys -x` exports it) and never written to disk;
# without it, from the login keychain's "esclop" account (the Mac that made the key).
# ESCLOP_APPCAST_NOTES=FILE takes the notes from FILE instead of CHANGELOG.md (tests).
#
# Every item goes to the default channel, the only one for now. A beta channel later is the same
# feed with <sparkle:channel>beta</sparkle:channel> on beta items and the app opting in through
# SPUUpdaterDelegate.allowedChannels(for:).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DMG=${1:?usage: Scripts/appcast.sh DMG URL OUT}
URL=${2:?usage: Scripts/appcast.sh DMG URL OUT}
OUT=${3:?usage: Scripts/appcast.sh DMG URL OUT}
BIN="$("$ROOT/Scripts/sparkle-tools.sh")"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/appcast.XXXXXX")"
mounted=""
cleanup() {
  [ -n "$mounted" ] && hdiutil detach -quiet "$mounted" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

# What the app in the DMG says it is.
hdiutil attach -quiet -nobrowse -readonly -noverify -mountpoint "$TMP/mnt" "$DMG"
mounted="$TMP/mnt"
app="$(find "$TMP/mnt" -maxdepth 1 -name '*.app' | head -1)"
[ -n "$app" ] || { echo "appcast: no app in $DMG" >&2; exit 1; }
plist="$app/Contents/Info.plist"
version="$(plutil -extract CFBundleShortVersionString raw -o - "$plist")"
build="$(plutil -extract CFBundleVersion raw -o - "$plist")"
minimum="$(plutil -extract LSMinimumSystemVersion raw -o - "$plist")"
hdiutil detach -quiet "$TMP/mnt"
mounted=""

if [ -n "${ESCLOP_APPCAST_NOTES:-}" ]; then
  cp "$ESCLOP_APPCAST_NOTES" "$TMP/notes.md"
else
  "$ROOT/Scripts/release-notes.sh" --changelog "$version" > "$TMP/notes.md"
fi

sign() { # sign_update arguments...
  if [ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]; then
    printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$BIN/sign_update" --ed-key-file - "$@"
  else
    "$BIN/sign_update" --account esclop "$@"
  fi
}
signature="$(sign -p "$DMG")"
length="$(stat -f %z "$DMG")"

python3 - "$TMP/notes.md" "$OUT" "$version" "$build" "$minimum" "$URL" "$length" "$signature" <<'PY'
import email.utils, sys
from xml.sax.saxutils import escape, quoteattr
notes_path, out, version, build, minimum, url, length, signature = sys.argv[1:]
notes = open(notes_path, encoding="utf-8").read().strip().replace("]]>", "]]]]><![CDATA[>")
xml = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>L'Esclop</title>
    <link>https://github.com/rgrvlsk/esclop</link>
    <description>New versions of L'Esclop, written by Scripts/appcast.sh.</description>
    <language>en</language>
    <item>
      <title>{escape("L'Esclop " + version)}</title>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{escape(build)}</sparkle:version>
      <sparkle:shortVersionString>{escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{escape(minimum)}</sparkle:minimumSystemVersion>
      <description sparkle:format="markdown"><![CDATA[{notes}]]></description>
      <enclosure url={quoteattr(url)} length={quoteattr(length)} type="application/x-apple-diskimage" sparkle:edSignature={quoteattr(signature)}/>
    </item>
  </channel>
</rss>
"""
open(out, "w", encoding="utf-8").write(xml)
PY
# The feed's own signature, embedded at the end of the file.
sign "$OUT" > /dev/null
grep -q 'sparkle-signatures' "$OUT" || { echo "appcast: the feed was not signed" >&2; exit 1; }
echo "appcast: $OUT for L'Esclop $version ($build), $length bytes, from $URL"
