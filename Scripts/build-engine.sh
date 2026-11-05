#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds esclop-engine for release and installs it as Binaries/esclop-engine.
#
# - Builds every macOS target whose Rust standard library is installed (aarch64-apple-darwin,
#   x86_64-apple-darwin); with rustup it adds both first. Two slices are merged with lipo.
# - Each target first gets the pinned libaom from Scripts/build-libaom.sh (needs cmake, and nasm
#   for x86_64), which the AVIF encoder links instead of libaom-sys's older bundled copy.
# - Strips, re-signs ad hoc (lipo and strip invalidate the linker's signature), then checks the
#   targets: each slice at most 15 MB, and no dynamic library outside /usr/lib and
#   /System/Library in any slice (Scripts/foreign-dylibs.sh).
#
# - Writes Binaries/LICENSES/libaom.txt, the licence of the C library statically in the engine.
#
# Usage: Scripts/build-engine.sh [--notices]   (--notices also regenerates
#        engine/THIRD_PARTY-engine.md with cargo about and the libaom record)
set -eu
cd "$(dirname "$0")/.."
NOTICES=0
for arg in "$@"; do
    case "$arg" in
        --notices) NOTICES=1 ;;
        *) echo "usage: Scripts/build-engine.sh [--notices]" >&2; exit 2 ;;
    esac
done

MAX_SLICE_BYTES=$((15 * 1024 * 1024))
OUT=Binaries/esclop-engine
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
# Rust embeds source paths in panic locations, including dependency paths under the home directory.
remap_home="--remap-path-prefix=$HOME=/build"
remap_repo="--remap-path-prefix=$(pwd)=/src/esclop"
if [ -n "${CARGO_ENCODED_RUSTFLAGS:-}" ]; then
    CARGO_ENCODED_RUSTFLAGS="$CARGO_ENCODED_RUSTFLAGS$(printf '\037')$remap_home$(printf '\037')$remap_repo"
else
    CARGO_ENCODED_RUSTFLAGS="$(printf '%s' "${RUSTFLAGS:-}" | tr ' ' '\037')"
    CARGO_ENCODED_RUSTFLAGS="${CARGO_ENCODED_RUSTFLAGS:+$CARGO_ENCODED_RUSTFLAGS$(printf '\037')}$remap_home$(printf '\037')$remap_repo"
fi
export CARGO_ENCODED_RUSTFLAGS

if command -v rustup >/dev/null 2>&1; then
    rustup target add aarch64-apple-darwin x86_64-apple-darwin >/dev/null
fi
SYSROOT="$(rustc --print sysroot)"
TARGETS=""
for t in aarch64-apple-darwin x86_64-apple-darwin; do
    if [ -d "$SYSROOT/lib/rustlib/$t/lib" ]; then
        TARGETS="$TARGETS $t"
    else
        echo "build-engine: skipping $t (its standard library is not installed; see engine/README.md)" >&2
    fi
done
[ -n "$TARGETS" ] || { echo "build-engine: no macOS Rust target installed" >&2; exit 1; }

SLICES=""
for t in $TARGETS; do
    # the AVIF encoder links the pinned libaom built for this target (see build-libaom.sh)
    eval "$(Scripts/build-libaom.sh --env "$t")"
    echo "build-engine: building $t" >&2
    cargo build --release --locked --manifest-path engine/Cargo.toml -p esclop-engine --bin esclop-engine --target "$t"
    SLICES="$SLICES engine/target/$t/release/esclop-engine"
done

mkdir -p Binaries
rm -f "$OUT"
set -- $SLICES
if [ $# -gt 1 ]; then
    lipo -create "$@" -output "$OUT"
else
    cp "$1" "$OUT"
fi
strip -x "$OUT"
codesign --force --sign - "$OUT" >/dev/null 2>&1

status=0
TMP_SLICE="$(mktemp -t esclop-slice)"
trap 'rm -f "$TMP_SLICE"' EXIT
for arch in $(lipo -archs "$OUT"); do
    if lipo -info "$OUT" | grep -q '^Non-fat'; then
        cp "$OUT" "$TMP_SLICE"
    else
        lipo "$OUT" -thin "$arch" -output "$TMP_SLICE"
    fi
    bytes=$(wc -c < "$TMP_SLICE" | tr -d ' ')
    echo "build-engine: $arch slice $bytes bytes (limit $MAX_SLICE_BYTES)" >&2
    if [ "$bytes" -gt "$MAX_SLICE_BYTES" ]; then
        echo "build-engine: FAIL $arch slice is over 15 MB" >&2
        status=1
    fi
done
# every slice of the universal file (Scripts/foreign-dylibs.sh skips otool's per-arch headers)
foreign=$(Scripts/foreign-dylibs.sh "$OUT")
if [ -n "$foreign" ]; then
    echo "build-engine: FAIL links libraries outside the system:" >&2
    echo "$foreign" >&2
    status=1
fi
"$OUT" --version >&2
# AVIF must come from the pinned libaom (tune=iq), not libaom-sys's bundled fallback
case "$("$OUT" hello)" in *'tune=iq'*) ;; *) echo "build-engine: FAIL esclop-engine lacks libaom tune=iq" >&2; status=1 ;; esac
# libaom is statically linked: its licence text goes with the binaries (LICENSES/libaom.txt)
Scripts/build-libaom.sh --licence Binaries/LICENSES

if [ "$NOTICES" = 1 ]; then
    (cd engine && cargo about generate -c about.toml about.hbs -o THIRD_PARTY-engine.md)
    Scripts/build-libaom.sh --notices >> engine/THIRD_PARTY-engine.md
fi
echo "build-engine: $(lipo -archs "$OUT") -> $OUT" >&2
exit $status
