#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Licence gate: every Mach-O file under DIR must have a licence record.
#
#   Scripts/licence-gate.sh [--dist] [--universal] [--max-mb N] DIR
#
# DIR is Binaries/, an .app bundle, or an unpacked release directory. For each Mach-O file
# (found by content, not by name) the gate looks up its record:
#   - third-party tools: a THIRD_PARTY.md row whose "Ships as" column names the file, with a
#     version, an SPDX licence allowed by policy, an https source URL and a SHA-256; its licence
#     text (and that of every component "static in" it) must be in LICENSES/ with a matching
#     provenance header (Source and SHA-256 lines written by Scripts/build-tools.sh);
#   - esclop-engine: engine/THIRD_PARTY-engine.md, which must list exactly the crates
#     `cargo tree` resolves for both macOS targets (checked when cargo is available) at the
#     versions in engine/Cargo.lock, plus a "static in `esclop-engine`" row (version, allowed
#     SPDX licence, https source, SHA-256) for each C library built outside cargo and linked in
#     (libaom), whose licence text must be in LICENSES/ like a tool's;
#   - L'Esclop's own executables (the CLI and the app): GPL-3.0-or-later, this repository;
#   - a framework in an app's Contents/Frameworks (Sparkle.framework, with its helpers and XPC
#     services): a Package.resolved pin of the same name, whose licence is checked like the
#     statically linked Swift packages' (LICENSES/swift-packages.md, with --dist).
# Any other Mach-O fails the gate, as does a linked library outside /usr/lib and /System
# (an unrecorded dylib is unrecorded third-party code).
#
# Policy is engine/deny.toml's licence allowlist, read with the GNU "or later" rule (a licence
# "X-N-or-later" passes when X at version N or later is allowed). GPL-2.0-only is accepted only
# for a tool that ships as its own executable and is never linked (gifsicle); see
# docs/ARCHITECTURE.md, Rules.
#
#   --dist       DIR is something we distribute: LICENSES/ must also hold esclop.txt (our
#                LICENSE), esclop-engine.md (the engine notices) and swift-packages.md (every
#                Package.resolved pin), as written by Scripts/package-release.sh.
#   --universal  every Mach-O must contain both arm64 and x86_64.
#   --max-mb N   fail when the Mach-O files add up to more than N MB (10^6 bytes).
#
# Exit status: 0 when every check passes, 1 when any fails, 2 on bad usage.
set -euo pipefail
TMPDIR="${TMPDIR:-/tmp}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
THIRD_PARTY="$ROOT/THIRD_PARTY.md"
ENGINE_NOTICES="$ROOT/engine/THIRD_PARTY-engine.md"
DENY="$ROOT/engine/deny.toml"
ABOUT="$ROOT/engine/about.toml"
LOCK="$ROOT/engine/Cargo.lock"
RESOLVED="$ROOT/Package.resolved"
# L'Esclop's own executables: the CLI and the app's main executable.
FIRST_PARTY="esclop EsclopApp"
# Licences only acceptable for a separate executable that is never linked.
AGGREGATE_ONLY="GPL-2.0-only"

DIST=0; UNIVERSAL=0; MAX_MB=""; DIR=""
usage() { sed -n '3,/^set -euo/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//' >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --dist) DIST=1;;
    --universal) UNIVERSAL=1;;
    --max-mb) [ $# -ge 2 ] || usage; MAX_MB=$2; shift;;
    -h|--help) usage;;
    -*) echo "licence-gate: unknown option $1" >&2; usage;;
    *) [ -z "$DIR" ] || usage; DIR=$1;;
  esac
  shift
done
[ -n "$DIR" ] && [ -d "$DIR" ] || { echo "licence-gate: give a directory" >&2; usage; }
DIR="$(cd "$DIR" && pwd)"

FAILS=0
fail() { echo "FAIL  $*"; FAILS=$((FAILS + 1)); }
note() { echo "note  $*"; }
TMP="$(mktemp -d "${TMPDIR%/}/licence-gate.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ------------------------------------------------------------------ policy
# The quoted strings of the `allow = [ ... ]` array in deny.toml.
awk '/^allow = \[/{on=1; next} on && /^\]/{exit} on' "$DENY" | grep -o '"[^"]*"' | tr -d '"' > "$TMP/allow"
[ -s "$TMP/allow" ] || { echo "licence-gate: no licence allowlist in engine/deny.toml" >&2; exit 1; }
# A GNU licence "X-N-or-later" may be taken under any later version of X, so it passes when the
# allowlist holds X at a version >= N (for example LGPL-2.0-or-later via LGPL-2.1-or-later).
allowed() {
  grep -qxF "$1" "$TMP/allow" && return 0
  case "$1" in
    GPL-*-or-later|LGPL-*-or-later|AGPL-*-or-later) ;;
    *) return 1;;
  esac
  awk -v want="$1" 'BEGIN { split(want, w, "-"); fam = w[1]; ver = w[2] + 0 }
    { split($0, a, "-") } a[1] == fam && (a[3] == "or" || a[3] == "only") && a[2] + 0 >= ver { ok = 1 }
    END { exit ok ? 0 : 1 }' "$TMP/allow"
}
# cargo about must not accept anything the policy does not.
awk '/^accepted = \[/{on=1; next} on && /^\]/{exit} on' "$ABOUT" | grep -o '"[^"]*"' | tr -d '"' |
  while read -r l; do allowed "$l" || echo "$l"; done > "$TMP/about-extra"
[ ! -s "$TMP/about-extra" ] || fail "engine/about.toml accepts licences outside deny.toml: $(tr '\n' ' ' < "$TMP/about-extra")"

# ------------------------------------------------------- tool records (THIRD_PARTY.md)
# rows.tsv: component \t ships-as \t version \t licence \t url \t sha
awk -F'|' 'NF >= 8 && $2 !~ /^ *(Component|---)/ {
  for (i = 2; i <= 7; i++) { gsub(/^ +| +$/, "", $i) }
  print $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6 "\t" $7 }' "$THIRD_PARTY" > "$TMP/rows.tsv"
[ -s "$TMP/rows.tsv" ] || fail "THIRD_PARTY.md has no component table"
# exe.tsv: executable \t row number  (for rows that ship as executables)
# static.tsv: executable \t row number  (components statically inside that executable)
: > "$TMP/exe.tsv"; : > "$TMP/static.tsv"
n=0
while IFS=$'\t' read -r comp ships ver lic url sha; do
  n=$((n + 1))
  [ -n "$ver" ] || fail "THIRD_PARTY.md: $comp has no version"
  case "$url" in https://*) ;; *) fail "THIRD_PARTY.md: $comp source is not an https URL: $url";; esac
  echo "$sha" | grep -qE '^[0-9a-f]{64}$' || fail "THIRD_PARTY.md: $comp has no SHA-256"
  names="$(echo "$ships" | grep -o '`[^`]*`' | tr -d '`' || true)"
  [ -n "$names" ] || fail "THIRD_PARTY.md: $comp says nothing about how it ships"
  case "$ships" in
    "static in "*)
      allowed "$lic" || fail "THIRD_PARTY.md: $comp is linked into a tool under $lic, which policy does not allow"
      for e in $names; do printf '%s\t%s\n' "$e" "$n" >> "$TMP/static.tsv"; done;;
    *)
      allowed "$lic" || case " $AGGREGATE_ONLY " in *" $lic "*) ;; *)
        fail "THIRD_PARTY.md: $comp is under $lic, which policy does not allow";; esac
      for e in $names; do printf '%s\t%s\n' "$e" "$n" >> "$TMP/exe.tsv"; done;;
  esac
done < "$TMP/rows.tsv"
cut -f1 "$TMP/static.tsv" | sort -u | while read -r e; do
  grep -q "^$e	" "$TMP/exe.tsv" || echo "$e"
done > "$TMP/orphans"
[ ! -s "$TMP/orphans" ] || fail "THIRD_PARTY.md: components are static in executables no row ships: $(tr '\n' ' ' < "$TMP/orphans")"
row() { sed -n "${1}p" "$TMP/rows.tsv"; }

# ----------------------------------------------------- engine record (THIRD_PARTY-engine.md)
ENGINE_OK=1
if [ ! -s "$ENGINE_NOTICES" ]; then
  ENGINE_OK=0
else
  grep '^Used by:' "$ENGINE_NOTICES" | grep -o '\[[^]]*\]' | tr -d '[]' | sort -u > "$TMP/notice-crates"
  # every listed crate at the version the lock file pins
  awk '/^\[\[package\]\]/{n=""} /^name = /{n=$3} /^version = /{v=$3; gsub(/"/,"",n); gsub(/"/,"",v); print n " " v}' "$LOCK" |
    sort -u > "$TMP/lock-crates"
  comm -23 "$TMP/notice-crates" "$TMP/lock-crates" > "$TMP/stale"
  if [ -s "$TMP/stale" ]; then
    ENGINE_OK=0
    fail "engine/THIRD_PARTY-engine.md lists crates not in Cargo.lock (stale; run Scripts/build-engine.sh --notices): $(head -5 "$TMP/stale" | tr '\n' ',')"
  fi
  if command -v cargo >/dev/null 2>&1; then
    for t in aarch64-apple-darwin x86_64-apple-darwin; do
      (cd "$ROOT/engine" && cargo tree --locked --offline -p esclop-engine -e normal --target "$t" --prefix none --format '{p}' 2>/dev/null) ||
        (cd "$ROOT/engine" && cargo tree --locked -p esclop-engine -e normal --target "$t" --prefix none --format '{p}')
    done | sed 's/ (.*//; s/ v/ /' | grep -v '^esclop-engine ' | sort -u > "$TMP/tree-crates"
    if [ -s "$TMP/tree-crates" ]; then
      comm -13 "$TMP/notice-crates" "$TMP/tree-crates" > "$TMP/missing"
      if [ -s "$TMP/missing" ]; then
        ENGINE_OK=0
        fail "engine/THIRD_PARTY-engine.md misses linked crates (run Scripts/build-engine.sh --notices): $(head -5 "$TMP/missing" | tr '\n' ',')"
      fi
    else
      note "cargo tree gave nothing; engine notices checked against Cargo.lock only"
    fi
  else
    note "cargo not found; engine notices checked against Cargo.lock only"
  fi
fi
# C libraries statically in the engine, outside cargo: rows of engine/THIRD_PARTY-engine.md shaped
# like THIRD_PARTY.md's, "| libaom | static in `esclop-engine` | ver | SPDX | url | sha |".
: > "$TMP/engine-static.tsv"
if [ -s "$ENGINE_NOTICES" ]; then
  awk -F'|' 'NF >= 8 && $3 ~ /static in `esclop-engine`/ {
      for (i = 2; i <= 7; i++) gsub(/^ +| +$/, "", $i); print $2 "\t" $4 "\t" $5 "\t" $6 "\t" $7 }' \
    "$ENGINE_NOTICES" > "$TMP/engine-static.tsv"
fi
while IFS=$'\t' read -r comp ver lic url sha; do
  [ -n "$ver" ] || fail "engine/THIRD_PARTY-engine.md: $comp has no version"
  allowed "$lic" || fail "engine/THIRD_PARTY-engine.md: $comp is linked into esclop-engine under $lic, which policy does not allow"
  case "$url" in https://*) ;; *) fail "engine/THIRD_PARTY-engine.md: $comp source is not an https URL: $url";; esac
  echo "$sha" | grep -qE '^[0-9a-f]{64}$' || fail "engine/THIRD_PARTY-engine.md: $comp has no SHA-256"
done < "$TMP/engine-static.tsv"

# ------------------------------------------------------------------ notices directory
LICDIR=""
for d in "$DIR/LICENSES" "$DIR/Contents/Resources/LICENSES"; do [ -d "$d" ] && { LICDIR=$d; break; }; done
# A licence file for a THIRD_PARTY.md row: header lines naming its source and SHA-256.
has_licence_text() { # url sha
  local t
  [ -n "$LICDIR" ] || return 1
  for t in "$LICDIR"/*.txt; do
    [ -f "$t" ] || continue
    if grep -qxF "Source:    $1" "$t" && grep -qxF "SHA-256:   $2" "$t"; then return 0; fi
  done
  return 1
}

# ------------------------------------------------------------------ Mach-O files
# Found by content (file(1)), so a renamed or extensionless binary is still found. Binaries/.cache
# holds build intermediates, not things we ship.
find "$DIR" -type f -not -path "$DIR/.cache/*" | sort | while IFS= read -r f; do
  case "$(file -b --mime-type "$f" 2>/dev/null)" in *mach*) echo "$f";; esac
done > "$TMP/macho"
[ -s "$TMP/macho" ] || fail "no Mach-O files under $DIR"

APP_EXEC=""
if [ -f "$DIR/Contents/Info.plist" ]; then
  APP_EXEC="$(plutil -extract CFBundleExecutable raw -o - "$DIR/Contents/Info.plist" 2>/dev/null || true)"
fi

# Frameworks the app carries, each from the Swift package pin of the same name (Sparkle):
# "Name<TAB>pin<TAB>version" lines. Links to @rpath/Name.framework/ are then not foreign.
: > "$TMP/frameworks.tsv"
for fw in "$DIR"/Contents/Frameworks/*.framework; do
  [ -d "$fw" ] || continue
  fname="$(basename "$fw" .framework)"
  pin="$(echo "$fname" | tr '[:upper:]' '[:lower:]')"
  i=0; pver=""
  while id="$(plutil -extract "pins.$i.identity" raw -o - "$RESOLVED" 2>/dev/null)"; do
    [ "$id" = "$pin" ] && { pver="$(plutil -extract "pins.$i.state.version" raw -o - "$RESOLVED" 2>/dev/null ||
      plutil -extract "pins.$i.state.revision" raw -o - "$RESOLVED")"; break; }
    i=$((i + 1))
  done
  if [ -n "$pver" ]; then printf '%s\t%s\t%s\n' "$fname" "$pin" "$pver" >> "$TMP/frameworks.tsv"
  else fail "Contents/Frameworks/$fname.framework comes from no Package.resolved pin"; fi
done
known_frameworks="$(cut -f1 "$TMP/frameworks.tsv" | sed 's/.*/@rpath\/&\\.framework\//' | paste -sd'|' -)"

TOTAL=0
seen_tools=""
printf '%-16s %-14s %-10s %-20s %s\n' FILE ARCHS VERSION LICENCE RECORD
while IFS= read -r f; do
  name="$(basename "$f")"
  rel="${f#"$DIR"/}"
  archs="$(lipo -archs "$f" 2>/dev/null | tr ' ' ',' || echo '?')"
  bytes=$(wc -c < "$f" | tr -d ' ')
  TOTAL=$((TOTAL + bytes))
  if [ "$UNIVERSAL" = 1 ]; then
    case ",$archs," in *,arm64,*) ;; *) fail "$rel: no arm64 slice ($archs)";; esac
    case ",$archs," in *,x86_64,*) ;; *) fail "$rel: no x86_64 slice ($archs)";; esac
  fi
  # Linked libraries outside the system are code with no record. @rpath/@executable_path
  # entries that resolve to the system's Swift runtime are allowed.
  # Every slice of a universal file is checked (Scripts/foreign-dylibs.sh).
  "$ROOT/Scripts/foreign-dylibs.sh" "$f" | grep -v -E '	@rpath/libswift[A-Za-z_]*\.dylib$' |
    { if [ -n "$known_frameworks" ]; then grep -v -E "	($known_frameworks)"; else cat; fi; } > "$TMP/foreign" || true
  [ ! -s "$TMP/foreign" ] ||
    fail "$rel links libraries outside the system: $(awk -F'\t' '{print $2 " (" $1 ")"}' "$TMP/foreign" | sort -u | tr '\n' ' ')"

  r="$(awk -F'\t' -v e="$name" '$1 == e {print $2; exit}' "$TMP/exe.tsv")"
  fw=""
  case "$rel" in Contents/Frameworks/*.framework/*) fw="${rel#Contents/Frameworks/}"; fw="${fw%%.framework/*}";; esac
  if [ -n "$fw" ]; then
    pin=""; pver=""
    IFS=$'\t' read -r _ pin pver <<< "$(awk -F'\t' -v n="$fw" '$1 == n' "$TMP/frameworks.tsv")" || true
    if [ -n "${pin:-}" ]; then
      printf '%-16s %-14s %-10s %-20s %s\n' "$name" "$archs" "$pver" "(swift-packages.md)" "Swift package $pin"
    else
      fail "$rel: in a framework with no Package.resolved pin"
    fi
  elif [ -n "$r" ]; then
    IFS=$'\t' read -r comp ships ver lic url sha <<< "$(row "$r")"
    printf '%-16s %-14s %-10s %-20s %s\n' "$name" "$archs" "$ver" "$lic" "THIRD_PARTY.md: $comp"
    seen_tools="$seen_tools $name"
    has_licence_text "$url" "$sha" || fail "$rel: no licence text for $comp $ver in LICENSES/"
    for sr in $(awk -F'\t' -v e="$name" '$1 == e {print $2}' "$TMP/static.tsv"); do
      IFS=$'\t' read -r scomp _ sver _ surl ssha <<< "$(row "$sr")"
      has_licence_text "$surl" "$ssha" || fail "$rel: no licence text for $scomp $sver (static in it) in LICENSES/"
    done
  elif [ "$name" = esclop-engine ]; then
    printf '%-16s %-14s %-10s %-20s %s\n' "$name" "$archs" "-" "GPL-3.0-or-later" "engine/THIRD_PARTY-engine.md ($(wc -l < "$TMP/notice-crates" 2>/dev/null | tr -d ' ') crates, $(wc -l < "$TMP/engine-static.tsv" | tr -d ' ') C libraries)"
    [ "$ENGINE_OK" = 1 ] || fail "$rel: engine notices missing or stale"
    while IFS=$'\t' read -r scomp sver _ surl ssha; do
      has_licence_text "$surl" "$ssha" || fail "$rel: no licence text for $scomp $sver (static in it) in LICENSES/"
    done < "$TMP/engine-static.tsv"
    # libaom announces itself in the binary; then it must have a row
    # (grep reads to the end: with pipefail, -q would make strings die of SIGPIPE)
    if strings -a "$f" 2>/dev/null | grep 'AOMedia Project AV1 Encoder' > /dev/null &&
       ! grep -q '^libaom	' "$TMP/engine-static.tsv"; then
      fail "$rel: contains libaom but engine/THIRD_PARTY-engine.md has no libaom row"
    fi
    if [ "$DIST" = 1 ]; then
      cmp -s "$ENGINE_NOTICES" "$LICDIR/esclop-engine.md" 2>/dev/null || fail "$rel: LICENSES/esclop-engine.md missing or differs from engine/THIRD_PARTY-engine.md"
    fi
  elif case " $FIRST_PARTY $APP_EXEC " in *" $name "*) true;; *) false;; esac; then
    printf '%-16s %-14s %-10s %-20s %s\n' "$name" "$archs" "-" "GPL-3.0-or-later" "L'Esclop (LICENSE, Package.resolved)"
    if [ "$DIST" = 1 ]; then
      cmp -s "$ROOT/LICENSE" "$LICDIR/esclop.txt" 2>/dev/null || fail "$rel: LICENSES/esclop.txt missing or differs from LICENSE"
      FIRST_PARTY_SEEN=1
    fi
  else
    printf '%-16s %-14s %-10s %-20s %s\n' "$name" "$archs" "?" "?" "none"
    fail "$rel: Mach-O file with no licence record"
  fi
done < "$TMP/macho"

# Statically linked Swift packages of our own executables (distributions only).
if [ "${FIRST_PARTY_SEEN:-0}" = 1 ] && [ -f "$RESOLVED" ]; then
  i=0
  while id="$(plutil -extract "pins.$i.identity" raw -o - "$RESOLVED" 2>/dev/null)"; do
    ver="$(plutil -extract "pins.$i.state.version" raw -o - "$RESOLVED" 2>/dev/null || plutil -extract "pins.$i.state.revision" raw -o - "$RESOLVED")"
    grep -qE "^\| $id \| $ver \| " "$LICDIR/swift-packages.md" 2>/dev/null ||
      fail "Swift package $id $ver (Package.resolved) has no entry in LICENSES/swift-packages.md"
    i=$((i + 1))
  done
  # licence column of the table: each SPDX term must be allowed by policy
  awk -F'|' 'NF >= 6 && $2 !~ /^ *(Package|---)/ { gsub(/^ +| +$/, "", $2); gsub(/^ +| +$/, "", $4); print $2 "\t" $4 }' \
    "$LICDIR/swift-packages.md" 2>/dev/null > "$TMP/swift-lic" || true
  while IFS=$'\t' read -r id lic; do
    for term in $(echo "$lic" | sed 's/ AND / /g; s/ OR / /g'); do
      allowed "$term" || fail "Swift package $id is under '$lic', which policy does not allow (or was not identified)"
    done
  done < "$TMP/swift-lic"
fi

for e in $(cut -f1 "$TMP/exe.tsv"); do
  case " $seen_tools " in *" $e "*) ;; *) note "THIRD_PARTY.md ships $e but it is not under $DIR";; esac
done

mb=$(awk -v b="$TOTAL" 'BEGIN { printf "%.1f", b / 1000000 }')
echo "total Mach-O size: $mb MB in $(wc -l < "$TMP/macho" | tr -d ' ') files${MAX_MB:+ (limit $MAX_MB MB)}"
if [ -n "$MAX_MB" ] && [ "$TOTAL" -gt $((MAX_MB * 1000000)) ]; then
  fail "Mach-O files add up to $mb MB, over the $MAX_MB MB limit"
fi

if [ "$FAILS" -gt 0 ]; then
  echo "licence gate: $FAILS failure(s)"
  exit 1
fi
echo "licence gate: passed"
