#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Tests Scripts/licence-gate.sh against small fixture directories: it must pass recorded files
# and fail on each kind of gap. Needs only the Command Line Tools (clang, lipo).
set -euo pipefail
TMPDIR="${TMPDIR:-/tmp}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/Scripts/licence-gate.sh"
T="$(mktemp -d "${TMPDIR%/}/licence-gate-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
pass=0; failed=0

# expect <want-exit> <grep-pattern> <description> -- gate args...
expect() {
  local want=$1 pat=$2 what=$3 got=0 out; shift 4
  out="$("$GATE" "$@" 2>&1)" || got=$?
  if [ "$got" = "$want" ] && { [ -z "$pat" ] || grep -q -- "$pat" <<< "$out"; }; then
    echo "ok    $what"; pass=$((pass + 1))
  else
    echo "FAIL  $what (exit $got, wanted $want${pat:+ and /$pat/})"; sed 's/^/      /' <<< "$out"
    failed=$((failed + 1))
  fi
}

# A licence file as Scripts/build-tools.sh writes it, for the THIRD_PARTY.md row of $1.
licence_for() { # component-name-in-table outfile
  local line url sha
  line="$(grep -F "| $1 |" "$ROOT/THIRD_PARTY.md")"
  url="$(awk -F'|' '{gsub(/ /, "", $6); print $6}' <<< "$line")"
  sha="$(awk -F'|' '{gsub(/ /, "", $7); print $7}' <<< "$line")"
  printf 'Component: %s\nVersion:   x\nSource:    %s\nSHA-256:   %s\n\nlicence text\n' "$1" "$url" "$sha" > "$2"
}

echo 'int main(void) { return 0; }' > "$T/main.c"
clang -arch arm64 -arch x86_64 -o "$T/universal" "$T/main.c"
clang -arch arm64 -o "$T/arm64only" "$T/main.c"

# 1. an executable nobody recorded
mkdir -p "$T/c1"; cp "$T/universal" "$T/c1/mystery"
expect 1 "mystery: Mach-O file with no licence record" "unrecorded executable fails" -- "$T/c1"

# 2. a recorded tool without its licence text
mkdir -p "$T/c2"; cp "$T/universal" "$T/c2/gifsicle"
expect 1 "no licence text for gifsicle" "recorded tool without LICENSES/ fails" -- "$T/c2"

# 3. the same with its licence text passes
mkdir -p "$T/c2/LICENSES"; licence_for gifsicle "$T/c2/LICENSES/gifsicle.txt"
expect 0 "licence gate: passed" "recorded tool with its licence text passes" -- "$T/c2"

# 4. a tool whose static components lack their texts
mkdir -p "$T/c4/LICENSES"; cp "$T/universal" "$T/c4/ffmpeg"; licence_for FFmpeg "$T/c4/LICENSES/ffmpeg.txt"
expect 1 "no licence text for LAME" "static component without licence text fails" -- "$T/c4"

# 5. a single-architecture file under --universal
mkdir -p "$T/c5/LICENSES"; cp "$T/arm64only" "$T/c5/gifsicle"; licence_for gifsicle "$T/c5/LICENSES/gifsicle.txt"
expect 1 "no x86_64 slice" "--universal rejects a thin binary" -- --universal "$T/c5"
expect 0 "" "a thin binary passes without --universal" -- "$T/c5"

# 6. size limit
expect 1 "over the 0 MB limit" "--max-mb fails when exceeded" -- --max-mb 0 "$T/c2"

# 7. a linked library outside the system is unrecorded code
mkdir -p "$T/c7/LICENSES"; licence_for gifsicle "$T/c7/LICENSES/gifsicle.txt"
echo 'int helper(void) { return 1; }' > "$T/lib.c"
clang -dynamiclib -arch arm64 -o "$T/libhelper.dylib" -install_name "$T/libhelper.dylib" "$T/lib.c"
printf 'int helper(void);\nint main(void) { return helper(); }\n' > "$T/uses.c"
clang -arch arm64 -o "$T/c7/gifsicle" "$T/uses.c" "$T/libhelper.dylib"
expect 1 "links libraries outside the system" "foreign dylib dependency fails" -- "$T/c7"

# 8. a distribution needs our own licence and the Swift package notices
mkdir -p "$T/c8/bin" "$T/c8/LICENSES"; cp "$T/universal" "$T/c8/bin/esclop"
expect 1 "LICENSES/esclop.txt missing" "--dist without our LICENSE fails" -- --dist "$T/c8"
cp "$ROOT/LICENSE" "$T/c8/LICENSES/esclop.txt"
if [ -f "$ROOT/Package.resolved" ]; then
  expect 1 "has no entry in LICENSES/swift-packages.md" "--dist without Swift package notices fails" -- --dist "$T/c8"
  i=0
  while id="$(plutil -extract "pins.$i.identity" raw -o - "$ROOT/Package.resolved" 2>/dev/null)"; do
    v="$(plutil -extract "pins.$i.state.version" raw -o - "$ROOT/Package.resolved")"
    echo "| $id | $v | MIT | https://example.invalid |" >> "$T/c8/LICENSES/swift-packages.md"
    i=$((i + 1))
  done
fi
expect 0 "licence gate: passed" "--dist with every notice passes" -- --dist "$T/c8"
echo "| unknown-pkg | 1.0.0 | UNKNOWN | https://example.invalid |" >> "$T/c8/LICENSES/swift-packages.md"
expect 1 "unknown-pkg is under 'UNKNOWN'" "--dist rejects a Swift package of unidentified licence" -- --dist "$T/c8"

# 9. the engine is recorded by its notices file, and its static C libraries by LICENSES/
mkdir -p "$T/c9"; cp "$T/universal" "$T/c9/esclop-engine"
expect 1 "no licence text for libaom" "a static C library of the engine needs its licence text" -- "$T/c9"
line="$(grep -F '| libaom |' "$ROOT/engine/THIRD_PARTY-engine.md")"
mkdir -p "$T/c9/LICENSES"
printf 'Component: libaom\nVersion:   x\nSource:    %s\nSHA-256:   %s\n\nlicence text\n' \
  "$(awk -F'|' '{gsub(/ /, "", $6); print $6}' <<< "$line")" "$(awk -F'|' '{gsub(/ /, "", $7); print $7}' <<< "$line")" \
  > "$T/c9/LICENSES/libaom.txt"
expect 0 "engine/THIRD_PARTY-engine.md" "esclop-engine is recorded by its notices" -- "$T/c9"
expect 1 "LICENSES/esclop-engine.md missing" "--dist needs the engine notices copied" -- --dist "$T/c9"

# 10. universal files: otool prints a header per architecture ("FILE (architecture arm64):"),
#     which is not a library; a foreign library in one slice only is still found
mkdir -p "$T/c10/LICENSES"; licence_for gifsicle "$T/c10/LICENSES/gifsicle.txt"
cp "$T/universal" "$T/c10/gifsicle"
expect 0 "licence gate: passed" "a universal file linking only system libraries passes" -- --universal "$T/c10"
clang -dynamiclib -arch x86_64 -o "$T/libhelper-x86.dylib" -install_name /opt/foreign/libhelper.dylib "$T/lib.c"
clang -arch x86_64 -o "$T/uses-x86" "$T/uses.c" "$T/libhelper-x86.dylib"
lipo -create "$T/arm64only" "$T/uses-x86" -output "$T/c10/gifsicle"
expect 1 "/opt/foreign/libhelper.dylib (x86_64)" "a foreign library in the x86_64 slice alone fails" -- --universal "$T/c10"

# 12. an app's framework from a Swift package pin (Sparkle): its files are recorded by the pin,
#     and the app's link to it is not foreign; a framework no pin names fails
fw="$T/c12/Contents/Frameworks/Sparkle.framework/Versions/B"
mkdir -p "$T/c12/Contents/MacOS" "$fw"
plutil -create xml1 "$T/c12/Contents/Info.plist"
plutil -insert CFBundleExecutable -string EsclopApp "$T/c12/Contents/Info.plist"
clang -dynamiclib -arch arm64 -o "$fw/Sparkle" -install_name @rpath/Sparkle.framework/Versions/B/Sparkle "$T/lib.c"
cp "$T/arm64only" "$fw/Autoupdate"
clang -arch arm64 -o "$T/c12/Contents/MacOS/EsclopApp" "$T/uses.c" "$fw/Sparkle" -Xlinker -rpath -Xlinker @executable_path/../Frameworks
if grep -q '"identity" : "sparkle"' "$ROOT/Package.resolved" 2>/dev/null; then
  expect 0 "Swift package sparkle" "a framework from a Package.resolved pin passes, and so does the app linking it" -- "$T/c12"
fi
mkdir -p "$T/c12/Contents/Frameworks/Mystery.framework/Versions/A"
cp "$T/arm64only" "$T/c12/Contents/Frameworks/Mystery.framework/Versions/A/Mystery"
expect 1 "Mystery.framework comes from no Package.resolved pin" "a framework no pin names fails" -- "$T/c12"

# 11. Scripts/foreign-dylibs.sh, which Scripts/build-engine.sh uses on the universal engine
check() { # description want got
  if [ "$2" = "$3" ]; then echo "ok    $1"; pass=$((pass + 1)); else
    echo "FAIL  $1: wanted [$2], got [$3]"; failed=$((failed + 1)); fi
}
DYLIBS="$ROOT/Scripts/foreign-dylibs.sh"
check "foreign-dylibs: universal system-only file lists nothing" "" "$("$DYLIBS" "$T/universal")"
check "foreign-dylibs: names the slice of a foreign library" "$(printf 'x86_64\t/opt/foreign/libhelper.dylib')" "$("$DYLIBS" "$T/c10/gifsicle")"
check "foreign-dylibs: thin file" "$(printf 'arm64\t%s' "$T/libhelper.dylib")" "$("$DYLIBS" "$T/c7/gifsicle")"
got=0; "$DYLIBS" "$T/main.c" >/dev/null 2>&1 || got=$?
check "foreign-dylibs: refuses a file that is not Mach-O" 1 "$got"

echo "licence-gate-test: $pass passed, $failed failed"
[ "$failed" = 0 ]
