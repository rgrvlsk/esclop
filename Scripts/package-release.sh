#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Builds the release artefacts into dist/ from Binaries/ (tools and esclop-engine, universal)
# and the repository at REF:
#   esclop-<ver>-cli.tar.gz             bin/esclop, libexec/esclop/<tools>, LICENSES/, THIRD_PARTY.md
#   esclop-<ver>-source.tar.zst         the repository at REF (git archive)
#   esclop-engine-<ver>-vendor.tar.zst  `cargo vendor` of engine/Cargo.lock (the C the -sys crates build included)
#   esclop-swift-<ver>-vendor.tar.zst   SwiftPM dependency sources at Package.resolved revisions
#   third-party-src-<ver>.tar.zst       the upstream tarballs of the tools, the patches and the build script
#   SHA256SUMS                          sha256 of each of the above
#   release-notes.md                    the CHANGELOG section for <ver> (Scripts/release-notes.sh)
#
#   Scripts/package-release.sh [--dry-run] [--ref REF] [--skip-vendor]
#
# The version is EsclopVersion.string (Sources/EsclopIPC/Protocol.swift). A release (no
# --dry-run) needs REF to be the tag v<ver> and CHANGELOG.md to have a [<ver>] section; a dry run
# accepts any REF, falls back to the Unreleased section and tolerates a single-architecture
# esclop-engine (a Rust without rustup's x86_64 target), with a warning.
# Signing: with ESCLOP_SIGN_IDENTITY every Mach-O is signed with that identity and the hardened
# runtime (ad hoc otherwise); with ESCLOP_NOTARY_PROFILE (a `notarytool store-credentials`
# keychain profile) they are also submitted for notarisation before packing.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
DRY=0; REF=""; VENDOR=1
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1;;
    --ref) REF=${2:?--ref needs a value}; shift;;
    --skip-vendor) VENDOR=0;;
    -h|--help) sed -n '3,/^set -euo/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "package-release: unknown argument $1" >&2; exit 2;;
  esac
  shift
done

say() { echo "==> $*" >&2; }
die() { echo "package-release: $*" >&2; exit 1; }
for t in zstd shasum git lipo codesign; do command -v "$t" >/dev/null || die "$t not found"; done

VERSION="$(sed -n 's/.*static let string = "\(.*\)".*/\1/p' Sources/EsclopIPC/Protocol.swift)"
[ -n "$VERSION" ] || die "no EsclopVersion.string in Sources/EsclopIPC/Protocol.swift"
REF="${REF:-$( [ "$DRY" = 1 ] && echo HEAD || echo "v$VERSION")}"
git rev-parse -q --verify "$REF^{commit}" >/dev/null || die "unknown ref $REF"
if [ "$DRY" = 0 ]; then
  [ "$VENDOR" = 1 ] || die "--skip-vendor is only allowed with --dry-run"
  [ "$(git rev-parse "$REF^{commit}")" = "$(git rev-parse -q --verify "v$VERSION^{commit}" || true)" ] ||
    die "$REF is not the tag v$VERSION; bump EsclopVersion.string or tag the right commit"
  [ "$(git rev-parse HEAD)" = "$(git rev-parse "$REF^{commit}")" ] || die "HEAD differs from $REF"
  [ -z "$(git status --porcelain)" ] || die "release requires a clean working tree"
fi
TOOLS="esclop-engine ffmpeg ffprobe gifsicle"
for t in $TOOLS; do [ -x "Binaries/$t" ] || die "Binaries/$t is missing (make tools engine)"; done

DIST="$ROOT/dist"
STAGE="$DIST/stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
rm -f "$DIST"/esclop-*.tar.* "$DIST"/third-party-src-*.tar.* "$DIST/SHA256SUMS" "$DIST/release-notes.md"
# bsdtar: no AppleDouble files or extended attributes, fixed owner, so archives do not carry
# anything of the build machine.
pack() { # dir-in-stage -> stdout
  COPYFILE_DISABLE=1 tar -C "$STAGE" --no-mac-metadata --no-xattrs --no-acls \
    --uid 0 --gid 0 --uname root --gname wheel -cf - "$1"
}

sign_all() { # files...
  if [ -n "${ESCLOP_SIGN_IDENTITY:-}" ]; then
    codesign --force --options runtime --timestamp --sign "$ESCLOP_SIGN_IDENTITY" "$@"
  else
    codesign --force --sign - "$@"
  fi
}

# ------------------------------------------------------------------ CLI
say "CLI $VERSION"
CLI="$STAGE/esclop-$VERSION"
mkdir -p "$CLI/bin" "$CLI/libexec/esclop"
Scripts/build-swift.sh esclop "$CLI/bin/esclop"
for t in $TOOLS; do cp "Binaries/$t" "$CLI/libexec/esclop/"; done
# Source paths can survive stripping, for example in panic messages and compiler literals.
for f in "$CLI/bin/esclop" "$CLI"/libexec/esclop/*; do
  if LC_ALL=C grep -aEq '/(Users|home)/[[:alnum:]_.-]+' "$f"; then
    strings -a "$f" | grep -E '/(Users|home)/[[:alnum:]_.-]+' | sort -u | head -5 >&2
    die "${f##*/} contains a home directory path (listed above); rebuild from a neutral directory"
  fi
done
Scripts/stage-notices.sh "$CLI/LICENSES"
cp THIRD_PARTY.md "$CLI/"
cat > "$CLI/README.txt" <<EOF
L'Esclop $VERSION, command line and MCP server (macOS 14 or later, Apple Silicon and Intel)

  bin/esclop              the command line; \`esclop mcp serve\` is the MCP server
  libexec/esclop/         ffmpeg, ffprobe, gifsicle and esclop-engine, found by bin/esclop
  LICENSES/               licence texts of everything above
  THIRD_PARTY.md          versions, sources and checksums of the bundled tools

Install: copy this directory anywhere (for example ~/.local/esclop) and link bin/esclop into a
folder on your PATH. Keep bin/ and libexec/ side by side.

L'Esclop is free software under the GNU GPL, version 3 or later. The complete corresponding
source of this release (the repository, the Swift packages, the vendored Rust crates and the
upstream tarballs of the bundled tools) is published next to this archive.
EOF
sign_all "$CLI/bin/esclop" "$CLI"/libexec/esclop/*
if [ -n "${ESCLOP_NOTARY_PROFILE:-}" ]; then
  say "notarising the CLI and tools"
  (cd "$STAGE" && ditto -c -k --keepParent "esclop-$VERSION" "$STAGE/notarise.zip")
  xcrun notarytool submit "$STAGE/notarise.zip" --keychain-profile "$ESCLOP_NOTARY_PROFILE" --wait
  rm -f "$STAGE/notarise.zip"
fi
# A dry run on a machine without rustup's x86_64 target has a thin engine; say so, do not stop.
gate_flags=(--dist --universal)
if [ "$DRY" = 1 ] && [ "$(lipo -archs Binaries/esclop-engine | wc -w | tr -d ' ')" -lt 2 ]; then
  echo "package-release: WARNING Binaries/esclop-engine is not universal; dry run continues (see engine/README.md)" >&2
  gate_flags=(--dist)
fi
Scripts/licence-gate.sh "${gate_flags[@]}" "$CLI" >&2
pack "esclop-$VERSION" | gzip -9 > "$DIST/esclop-$VERSION-cli.tar.gz"

# ------------------------------------------------------------------ source
say "source at $REF"
git archive --format=tar --prefix="esclop-$VERSION/" "$REF" | zstd -q -19 -T0 -o "$DIST/esclop-$VERSION-source.tar.zst"

# ------------------------------------------------------------------ Swift dependencies
say "Swift package sources"
SV="$STAGE/esclop-swift-$VERSION-vendor"
Scripts/swift-sources.sh "$SV"
pack "esclop-swift-$VERSION-vendor" | zstd -q -19 -T0 -o "$DIST/esclop-swift-$VERSION-vendor.tar.zst"

# ------------------------------------------------------------------ engine vendor
if [ "$VENDOR" = 1 ]; then
  say "cargo vendor"
  V="$STAGE/esclop-engine-$VERSION-vendor"
  mkdir -p "$V/.cargo"
  # crates as of REF, not of the working tree
  git show "$REF:engine/Cargo.lock" > "$STAGE/Cargo.lock.ref"
  cmp -s "$STAGE/Cargo.lock.ref" engine/Cargo.lock || die "engine/Cargo.lock differs from $REF"
  (cd "$V" && cargo vendor --locked --versioned-dirs --manifest-path "$ROOT/engine/Cargo.toml" vendor > .cargo/config.toml)
  cat > "$V/README.txt" <<EOF
Vendored Rust crates of esclop-engine $VERSION (cargo vendor of engine/Cargo.lock), including
the C sources the -sys crates compile (mozjpeg, libwebp). To build offline, move vendor/ and
.cargo/ into the engine/ directory of esclop-$VERSION-source and run Scripts/build-engine.sh.
EOF
  pack "esclop-engine-$VERSION-vendor" | zstd -q -19 -T0 -o "$DIST/esclop-engine-$VERSION-vendor.tar.zst"
else
  say "cargo vendor skipped (--skip-vendor)"
fi

# ------------------------------------------------------------------ third-party source
say "third-party sources"
TP="$STAGE/third-party-src-$VERSION"
mkdir -p "$TP/tarballs" "$TP/Scripts" "$TP/docs" "$TP/Binaries"
# Every tarball THIRD_PARTY.md records (the tools) and engine/THIRD_PARTY-engine.md records (C
# libraries static in esclop-engine), found in the build cache by its SHA-256.
{
  awk -F'|' 'NF >= 8 && $2 !~ /^ *(Component|---)/ { gsub(/ /, "", $7); print $7 }' THIRD_PARTY.md
  awk -F'|' 'NF >= 8 && $3 ~ /static in `esclop-engine`/ { gsub(/ /, "", $7); print $7 }' engine/THIRD_PARTY-engine.md
} > "$STAGE/shas"
[ -s "$STAGE/shas" ] || die "no tarballs recorded in THIRD_PARTY.md"
for f in Binaries/.cache/dl/*; do [ -f "$f" ] && echo "$(shasum -a 256 "$f" | cut -d' ' -f1) $f"; done > "$STAGE/have" || true
while read -r sha; do
  f="$(awk -v s="$sha" '$1 == s {print $2; exit}' "$STAGE/have")"
  [ -n "$f" ] || die "no tarball with sha256 $sha in Binaries/.cache/dl (run Scripts/build-tools.sh and Scripts/build-engine.sh)"
  cp "$f" "$TP/tarballs/"
done < "$STAGE/shas"
cp -R Binaries/patches "$TP/Binaries/patches"
cp Scripts/build-tools.sh Scripts/build-libaom.sh "$TP/Scripts/"
cp docs/build-tools.md "$TP/docs/"
cp THIRD_PARTY.md "$TP/"
mkdir -p "$TP/engine" && cp engine/THIRD_PARTY-engine.md "$TP/engine/"
cat > "$TP/README.txt" <<EOF
Corresponding source of the tools bundled with L'Esclop $VERSION: the exact upstream tarballs
(tarballs/, checksums in THIRD_PARTY.md), the patches applied to them (Binaries/patches/) and
the script that builds them (Scripts/build-tools.sh, documented in docs/build-tools.md). Also
libaom, statically linked into esclop-engine: its tarball (checksum in
engine/THIRD_PARTY-engine.md) and Scripts/build-libaom.sh.

To rebuild offline from esclop-$VERSION-source: copy tarballs/* into Binaries/.cache/dl/ and
run Scripts/build-tools.sh. It reuses every tarball whose SHA-256 matches its pin.
EOF
pack "third-party-src-$VERSION" | zstd -q -19 -T0 -o "$DIST/third-party-src-$VERSION.tar.zst"

# ------------------------------------------------------------------ notes and checksums
if [ "$DRY" = 1 ]; then
  Scripts/release-notes.sh "$VERSION" > "$DIST/release-notes.md" 2>/dev/null ||
    Scripts/release-notes.sh --unreleased "$VERSION" > "$DIST/release-notes.md"
else
  Scripts/release-notes.sh "$VERSION" > "$DIST/release-notes.md"
fi
(cd "$DIST" && shasum -a 256 esclop-*.tar.* third-party-src-*.tar.* > SHA256SUMS)
rm -rf "$STAGE"
say "artefacts in dist/"
(cd "$DIST" && ls -l esclop-*.tar.* third-party-src-*.tar.* SHA256SUMS release-notes.md | awk '{printf "  %10s  %s\n", $5, $9}') >&2
