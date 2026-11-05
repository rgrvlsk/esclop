#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds libaom (static, 8-bit, no tools or tests) from its pinned, checksummed upstream release
# for one Rust target, for esclop-engine's AVIF encoder.
#
# Why not the copy inside the libaom-sys crate: it is libaom 3.11, which predates `tune=iq`
# (libaom 3.12+). That one setting is worth ~30 % of an AVIF file at L'Esclop's normal
# compression (engine/bench/README.md), and it is what Clop's heif-enc uses.
#
# The tarball goes to Binaries/.cache/dl/ (where Scripts/package-release.sh collects upstream
# sources by SHA-256) and the build to Binaries/.cache/libaom/<target>/; CI caches both by the
# tarball's SHA-256 and this script's hash.
#
# Usage: Scripts/build-libaom.sh [MODE] [TARGET]      TARGET defaults to the host
#   (no mode)      build if needed, print the install prefix
#   --env          print the LIB_AOM_* exports libaom-sys reads, e.g.
#                    eval "$(Scripts/build-libaom.sh --env)" && (cd engine && cargo test)
#   --github-env   the same as NAME=value lines for $GITHUB_ENV
#   --licence DIR  write DIR/libaom.txt: provenance header and licence texts, in the format
#                  Scripts/build-tools.sh writes and Scripts/licence-gate.sh checks
#   --notices      print the table rows engine/THIRD_PARTY-engine.md records libaom with
#   --sha256       print the tarball's pinned SHA-256 (for cache keys)
set -eu
cd "$(dirname "$0")/.."

AOM_VERSION=3.15.3
AOM_SHA256=12c01dc731ed7b5a999e28120b45bf58a002ba3435a4ba2cfbc1e084a27c9c04
AOM_URL="https://storage.googleapis.com/aom-releases/libaom-$AOM_VERSION.tar.gz"
AOM_LICENCE="BSD-2-Clause"

MODE=build
LICDIR=""
case "${1:-}" in
    --env|--github-env|--notices|--sha256) MODE=${1#--}; shift ;;
    --licence) MODE=licence; LICDIR=${2:?--licence needs a directory}; shift 2 ;;
    -*) echo "build-libaom: unknown option $1" >&2; exit 2 ;;
esac

if [ "$MODE" = sha256 ]; then echo "$AOM_SHA256"; exit 0; fi

TARGET="${1:-$(rustc -vV | sed -n 's/^host: //p')}"
case "$TARGET" in
    aarch64-apple-darwin) ARCH=arm64 CPU=arm64 ;;
    x86_64-apple-darwin) ARCH=x86_64 CPU=x86_64 ;;
    *) echo "build-libaom: unsupported target $TARGET" >&2; exit 2 ;;
esac

ROOT="$(pwd)"
DL="$ROOT/Binaries/.cache/dl"
WORK="$ROOT/Binaries/.cache/libaom"
TARBALL="$DL/libaom-$AOM_VERSION.tar.gz"
SRC="$WORK/libaom-$AOM_VERSION"
PREFIX="$WORK/$AOM_VERSION-$TARGET"
mkdir -p "$DL" "$WORK"

fetch_and_unpack() {
    if [ ! -f "$TARBALL" ]; then
        echo "build-libaom: fetching $AOM_URL" >&2
        curl -sSfL --retry 3 -o "$TARBALL.part" "$AOM_URL"
        mv "$TARBALL.part" "$TARBALL"
    fi
    actual="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
    if [ "$actual" != "$AOM_SHA256" ]; then
        echo "build-libaom: checksum mismatch for $TARBALL ($actual)" >&2
        rm -f "$TARBALL"
        exit 1
    fi
    [ -d "$SRC" ] || tar -xzf "$TARBALL" -C "$WORK"
}

if [ "$MODE" = notices ]; then
    fetch_and_unpack
    echo
    echo "## Statically linked C libraries"
    echo
    echo "Built from pinned upstream source by the script named, not by cargo; Scripts/licence-gate.sh"
    echo "checks each row against the licence policy and LICENSES/."
    echo
    echo "| Component | Ships as | Version | Licence (SPDX) | Source | SHA-256 |"
    echo "| --- | --- | --- | --- | --- | --- |"
    printf '| libaom | static in `esclop-engine` | %s | %s | %s | %s |\n' "$AOM_VERSION" "$AOM_LICENCE" "$AOM_URL" "$AOM_SHA256"
    echo
    echo "libaom $AOM_VERSION, built by \`Scripts/build-libaom.sh\` (8-bit, static, no tools)."
    for f in LICENSE PATENTS; do
        printf '\n### libaom %s\n\n```\n' "$f"; cat "$SRC/$f"; printf '```\n'
    done
    exit 0
fi

if [ "$MODE" = licence ]; then
    fetch_and_unpack
    mkdir -p "$LICDIR"
    {
        echo "Component: libaom"; echo "Version:   $AOM_VERSION"; echo "Source:    $AOM_URL"; echo "SHA-256:   $AOM_SHA256"
        for f in LICENSE PATENTS; do
            echo; echo "-------------------------------------------------------------------------------"
            echo "File: $f"; echo "-------------------------------------------------------------------------------"
            cat "$SRC/$f"
        done
    } > "$LICDIR/libaom.txt"
    exit 0
fi

if [ ! -f "$PREFIX/lib/libaom.a" ]; then
    fetch_and_unpack
    BUILD="$WORK/build-$AOM_VERSION-$TARGET"
    rm -rf "$BUILD"
    echo "build-libaom: building libaom $AOM_VERSION for $TARGET" >&2
    LOG="$WORK/build-$AOM_VERSION-$TARGET.log"
    fail() { echo "build-libaom: $1 failed; last lines of $LOG:" >&2; tail -40 "$LOG" >&2; exit 1; }
    cmake -S "$SRC" -B "$BUILD" -G "Unix Makefiles" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}" \
        -DAOM_TARGET_CPU="$CPU" \
        -DBUILD_SHARED_LIBS=0 \
        -DCONFIG_AV1_HIGHBITDEPTH=0 \
        -DCONFIG_WEBM_IO=0 \
        -DENABLE_DOCS=0 -DENABLE_EXAMPLES=0 -DENABLE_TESTDATA=0 -DENABLE_TESTS=0 -DENABLE_TOOLS=0 \
        > "$LOG" 2>&1 || fail "cmake configure"
    cmake --build "$BUILD" -j "$(sysctl -n hw.ncpu)" >> "$LOG" 2>&1 || fail "build"
    cmake --install "$BUILD" >> "$LOG" 2>&1 || fail "install"
    rm -rf "$BUILD" "$LOG"
fi

case "$MODE" in
    env)
        echo "export LIB_AOM_STATIC_LIB_PATH='$PREFIX/lib'"
        echo "export LIB_AOM_INCLUDE_PATH='$PREFIX/include'"
        echo "export LIB_AOM_PKG_CONFIG_PATH='$PREFIX/lib/pkgconfig'"
        ;;
    github-env)
        echo "LIB_AOM_STATIC_LIB_PATH=$PREFIX/lib"
        echo "LIB_AOM_INCLUDE_PATH=$PREFIX/include"
        echo "LIB_AOM_PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig"
        ;;
    *) echo "$PREFIX" ;;
esac
