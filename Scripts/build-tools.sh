#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Builds the command-line tools esclop bundles (ffmpeg, ffprobe, gs, gifsicle)
# from pinned upstream SOURCE tarballs into Binaries/ as universal
# (arm64 + x86_64) executables. It never downloads prebuilt binaries.
#
#   Scripts/build-tools.sh [--force] [--verify] [--no-verify] [ffmpeg|gs|gifsicle ...]
#
# See docs/build-tools.md. Targets bash 3.2 (the macOS system bash).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/Binaries"
CACHE="$BIN/.cache"
DLDIR="$CACHE/dl"
PATCHES="$BIN/patches"
THIRD_PARTY="$ROOT/THIRD_PARTY.md"
SELF="$ROOT/Scripts/build-tools.sh"

export MACOSX_DEPLOYMENT_TARGET=14.0
ARCHES="arm64 x86_64"
JOBS="$(sysctl -n hw.ncpu)"

# ---------------------------------------------------------------- pins
# Bumping a version: change VER, URL and SHA together (see docs/build-tools.md).
FFMPEG_VER=9.0.2
FFMPEG_URL=https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz
FFMPEG_SHA=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e

LAME_VER=3.100
LAME_URL=https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz
LAME_SHA=ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e

OPUS_VER=1.6.1
OPUS_URL=https://downloads.xiph.org/releases/opus/opus-1.6.1.tar.gz
OPUS_SHA=6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1

VPX_VER=1.17.0
VPX_URL=https://github.com/webmproject/libvpx/archive/refs/tags/v1.17.0.tar.gz
VPX_SHA=1020f184046187baa2985dbde38e0691f49c44088bca7a1842b0236c6081dc0a

SVT_VER=4.3.0
SVT_URL=https://gitlab.com/AOMediaCodec/SVT-AV1/-/archive/v4.3.0/SVT-AV1-v4.3.0.tar.gz
SVT_SHA=95ce8fc2381ba707e65ac8b9b2e165915bfbe9cd4d2f7b0f58d64ce31bd98f6d

GS_VER=10.08.0
GS_URL=https://github.com/ArtifexSoftware/ghostpdl-downloads/releases/download/gs10080/ghostscript-10.08.0.tar.xz
GS_SHA=c20492bc8ebb96c87fa2e52a0926e1cda8cde95d66145e018ac713fed5da38cf

GIFSICLE_VER=1.98
GIFSICLE_URL=https://www.lcdf.org/gifsicle/gifsicle-1.98.tar.gz
GIFSICLE_SHA=e9d4cc0816db95c64d32e79f778836db0f1f7eb15868490bd330104e5146b66e

# ---------------------------------------------------------------- common
#>> RECIPE common
die() { echo "error: $*" >&2; exit 1; }
say() { echo "==> $*"; }
sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }

# Download a pinned tarball into the cache and verify its hash; mismatch is fatal.
fetch() { # url sha filename -> prints local path
  local url=$1 sha=$2 f="$DLDIR/$3" got
  mkdir -p "$DLDIR"
  if [ -f "$f" ] && [ "$(sha256 "$f")" = "$sha" ]; then echo "$f"; return; fi
  rm -f "$f" "$f.part"
  echo "  downloading $url" >&2
  curl -fL --retry 6 --retry-all-errors --retry-delay 5 --connect-timeout 20 --speed-limit 20000 --speed-time 30 -sS -o "$f.part" "$url" || die "download failed: $url"
  got="$(sha256 "$f.part")"
  if [ "$got" != "$sha" ]; then
    rm -f "$f.part"
    die "sha256 mismatch for $url (expected $sha, got $got)"
  fi
  mv "$f.part" "$f"
  echo "$f"
}

# Extract into a fresh directory; result in $SRC. Archives are untrusted: only
# their build systems are ever run.
unpack_nopatch() { # tarball destdir
  rm -rf "$2"; mkdir -p "$2"
  tar -xf "$1" -C "$2"
  [ "$(ls "$2" | wc -l | tr -d ' ')" = 1 ] || die "unexpected layout in $1"
  SRC="$2/$(ls "$2")"
}

# Same, then apply Binaries/patches/<comp>/*.patch in name order.
unpack() { # comp tarball destdir
  local p
  unpack_nopatch "$2" "$3"
  for p in "$PATCHES/$1"/*.patch; do
    [ -f "$p" ] || continue
    patch -p1 -s -d "$SRC" < "$p" || die "patch failed: $p"
  done
}

in_dir() { local d=$1; shift; (cd "$d" && "$@"); }

# Run a build step with its output in a log; show the tail on failure.
step() { # name cmd...
  local n=$1; shift
  echo "  - $n"
  if ! "$@" >"$LOGS/$n.log" 2>&1; then
    tail -40 "$LOGS/$n.log" >&2
    rm -rf "$CACHE/failed-logs"; mkdir -p "$CACHE"; cp -R "$LOGS" "$CACHE/failed-logs"
    die "step '$n' failed (logs kept in Binaries/.cache/failed-logs)"
  fi
}

# Per-architecture compiler environment. PATH is reduced so Homebrew libraries
# can never leak into the build; only the build tools are linked in.
use_arch() { # arm64|x86_64
  ARCH=$1
  PFX="$WORK/prefix-$ARCH"; mkdir -p "$PFX/lib" "$PFX/include"
  case "$ARCH" in
    arm64)  HOST_TRIPLE=aarch64-apple-darwin; VPX_TARGET=arm64-darwin23-gcc ;;
    x86_64) HOST_TRIPLE=x86_64-apple-darwin;  VPX_TARGET=x86_64-darwin23-gcc ;;
  esac
  export PATH="$TOOLBIN:/usr/bin:/bin:/usr/sbin:/sbin"
  export CC="clang -arch $ARCH" CXX="clang++ -arch $ARCH"
  export CFLAGS="-O2 -mmacosx-version-min=14.0 -I$PFX/include"
  export CXXFLAGS="$CFLAGS"
  export LDFLAGS="-mmacosx-version-min=14.0 -L$PFX/lib"
  export PKG_CONFIG_LIBDIR="$PFX/lib/pkgconfig"
  unset PKG_CONFIG_PATH || true
}

# Merge slices, strip, then sign ad hoc (strip invalidates signatures and
# arm64 refuses to run unsigned code).
make_universal() { # outfile infile-arm64 infile-x86_64
  lipo -create -output "$1" "$2" "$3"
  strip "$1"
  codesign -f -s - "$1" >/dev/null 2>&1
  chmod 755 "$1"
}

# Concatenate licence files from an unpacked tree under a provenance header.
write_license() { # outfile component version url sha srcdir file...
  local out=$1 comp=$2 ver=$3 url=$4 sha=$5 dir=$6 f; shift 6
  mkdir -p "$(dirname "$out")"
  {
    echo "Component: $comp"; echo "Version:   $ver"; echo "Source:    $url"; echo "SHA-256:   $sha"
    for f in "$@"; do
      echo; echo "-------------------------------------------------------------------------------"
      echo "File: $f"; echo "-------------------------------------------------------------------------------"
      cat "$dir/$f"
    done
  } > "$out"
}
#<< RECIPE common

# ------------------------------------------------------------ ffmpeg
#>> RECIPE ffmpeg
# ffmpeg is configured with --disable-everything and these allowlists. Decoders, demuxers and
# parsers cover what people drop on the app (QuickTime/MP4, Matroska/WebM, AVI, MPEG-PS/TS,
# FLV, the usual audio files and cover art; not Windows Media, VC-1 or AMR); encoders, muxers
# and filters are what Sources/EsclopOptimisers asks for. A component missing here fails the
# verification below or a media test, not silently. wrapped_avframe decodes lavfi sources.
FF_DECODERS="wrapped_avframe h264 hevc prores mpeg4 mpeg2video mpeg1video h263 flv vp8 vp9 theora mjpeg png apng gif bmp qtrle rawvideo dvvideo aac aac_latm mp3float mp3 mp2float mp2 ac3 eac3 dca alac flac opus vorbis pcm_s16le pcm_s16be pcm_s24le pcm_s24be pcm_s32le pcm_s32be pcm_f32le pcm_f32be pcm_f64le pcm_u8 pcm_alaw pcm_mulaw adpcm_ima_wav adpcm_ima_qt adpcm_ms"
FF_DEMUXERS="mov matroska avi mpegps mpegts flv mp3 aac ac3 eac3 dts flac ogg wav w64 aiff caf h264 hevc m4v mpegvideo mjpeg image2 gif"
FF_PARSERS="h264 hevc mpeg4video mpegvideo mpegaudio aac aac_latm ac3 dca h263 vp8 vp9 av1 opus vorbis flac mjpeg png gif"
# ffprobe is a separate, probe-only build: the same demuxers and parsers, and only the decoders
# whose headers fill the fields MediaProbe.swift reads (pixel format, colour space, PCM bit
# rate). Linked into the ffmpeg build it would carry every encoder (about 15 MB per slice).
FF_PROBE_DECODERS="h264 hevc vp8 vp9 prores mjpeg png gif mpeg4 mpeg2video pcm_s16le pcm_s16be pcm_s24le pcm_s24be pcm_s32le pcm_s32be pcm_f32le pcm_f32be pcm_f64le pcm_u8 pcm_alaw pcm_mulaw"
FF_BSFS="aac_adtstoasc extract_extradata h264_mp4toannexb hevc_mp4toannexb mpeg4_unpack_bframes vp9_superframe vp9_superframe_split null"
FF_ENCODERS="h264_videotoolbox hevc_videotoolbox prores_videotoolbox libsvtav1 libvpx_vp9 libopus libmp3lame aac aac_at alac_at flac pcm_s16le pcm_s16be pcm_s24le adpcm_ima_wav png mjpeg gif rawvideo wrapped_avframe"
FF_MUXERS="mp4 mov ipod matroska webm mp3 adts ogg opus flac wav aiff gif image2 null mjpeg"
# buffer/buffersink/trim/asetpts/fifo are inserted by the ffmpeg CLI itself and
# must be present for any filter graph to run.
FF_FILTERS="scale crop pad fps setpts atempo aresample aformat format loudnorm palettegen paletteuse split null anull transpose hflip vflip rotate copy testsrc2 color sine anullsrc buffer abuffer buffersink abuffersink trim atrim asetpts fifo afifo asplit setsar setdar overlay colorchannelmixer scale2ref"

join_comma() { local IFS=,; echo "$*"; }

# Fills FF_FLAGS for one architecture. $1 = arch, $2 = install prefix.
ffmpeg_flags() {
  local arch=$1 p=$2
  FF_FLAGS=(
    "--prefix=$p"
    --cc=clang --cxx=clang++
    "--extra-cflags=-arch $arch -mmacosx-version-min=14.0 -I$p/include"
    "--extra-ldflags=-arch $arch -mmacosx-version-min=14.0 -L$p/lib -Wl,-dead_strip"
    --pkg-config-flags=--static
    "--arch=$arch" --target-os=darwin
    --enable-static --disable-shared
    --disable-debug --disable-doc --disable-ffplay --enable-ffmpeg --disable-ffprobe
    --disable-autodetect --disable-network
    --enable-pthreads
    --enable-videotoolbox --enable-audiotoolbox
    --enable-zlib --enable-bzlib --enable-iconv --extra-libs=-liconv
    --enable-libsvtav1 --enable-libvpx --enable-libopus --enable-libmp3lame
    --disable-everything
    --enable-indev=lavfi
    "--enable-decoder=$(join_comma $FF_DECODERS)"
    "--enable-demuxer=$(join_comma $FF_DEMUXERS)"
    "--enable-parser=$(join_comma $FF_PARSERS)"
    "--enable-bsf=$(join_comma $FF_BSFS)"
    "--enable-encoder=$(join_comma $FF_ENCODERS)"
    "--enable-muxer=$(join_comma $FF_MUXERS)"
    "--enable-filter=$(join_comma $FF_FILTERS)"
    --enable-protocol=file,pipe
  )
  if [ "$arch" != arm64 ]; then
    FF_FLAGS+=(--enable-cross-compile --x86asmexe=nasm)
  fi
}

# Fills FFPROBE_FLAGS: no encoders, filters, scaling, resampling or external libraries.
ffprobe_flags() {
  local arch=$1
  FFPROBE_FLAGS=(
    --cc=clang
    "--extra-cflags=-arch $arch -mmacosx-version-min=14.0"
    "--extra-ldflags=-arch $arch -mmacosx-version-min=14.0 -Wl,-dead_strip"
    "--arch=$arch" --target-os=darwin
    --enable-static --disable-shared
    --disable-debug --disable-doc --disable-ffplay --disable-ffmpeg --enable-ffprobe
    --disable-autodetect --disable-network
    --enable-pthreads
    --enable-zlib --enable-bzlib --enable-iconv --extra-libs=-liconv
    # Probing only reads headers, so ffprobe can be optimised for size (ffmpeg cannot: with
    # --enable-small its H.264/HEVC decoding is 20-30 % slower).
    --enable-small
    --disable-everything --disable-avdevice --disable-avfilter --disable-swscale --disable-swresample
    "--enable-decoder=$(join_comma $FF_PROBE_DECODERS)"
    "--enable-demuxer=$(join_comma $FF_DEMUXERS)"
    "--enable-parser=$(join_comma $FF_PARSERS)"
    --enable-protocol=file,pipe
  )
  if [ "$arch" != arm64 ]; then
    FFPROBE_FLAGS+=(--enable-cross-compile --x86asmexe=nasm)
  fi
}

build_lame() {
  unpack lame "$T_LAME" "$WORK/src-lame-$ARCH"
  step "lame-$ARCH-configure" in_dir "$SRC" ./configure --host="$HOST_TRIPLE" --prefix="$PFX" \
    --disable-shared --enable-static --disable-frontend --disable-decoder --disable-gtktest
  step "lame-$ARCH-make" in_dir "$SRC" make -j"$JOBS"
  step "lame-$ARCH-install" in_dir "$SRC" make install
}

build_opus() {
  unpack opus "$T_OPUS" "$WORK/src-opus-$ARCH"
  step "opus-$ARCH-configure" in_dir "$SRC" ./configure --host="$HOST_TRIPLE" --prefix="$PFX" \
    --disable-shared --enable-static --disable-doc --disable-extra-programs
  step "opus-$ARCH-make" in_dir "$SRC" make -j"$JOBS"
  step "opus-$ARCH-install" in_dir "$SRC" make install
}

build_vpx() {
  unpack libvpx "$T_VPX" "$WORK/src-vpx-$ARCH"
  # libvpx derives -arch and -mmacosx-version-min from the target string itself.
  step "vpx-$ARCH-configure" in_dir "$SRC" env -u CC -u CXX -u CFLAGS -u CXXFLAGS -u LDFLAGS \
    ./configure --target="$VPX_TARGET" --prefix="$PFX" \
    --disable-vp8 --enable-vp9 --disable-vp9-decoder --enable-vp9-highbitdepth --enable-pic --enable-runtime-cpu-detect \
    --disable-shared --enable-static --disable-examples --disable-tools --disable-docs --disable-unit-tests
  step "vpx-$ARCH-make" in_dir "$SRC" env -u CC -u CXX -u CFLAGS -u CXXFLAGS -u LDFLAGS make -j"$JOBS"
  step "vpx-$ARCH-install" in_dir "$SRC" env -u CC -u CXX -u CFLAGS -u CXXFLAGS -u LDFLAGS make install
}

build_svt() {
  unpack svt-av1 "$T_SVT" "$WORK/src-svt-$ARCH"
  step "svt-$ARCH-configure" cmake -S "$SRC" -B "$SRC/_build" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PFX" -DCMAKE_INSTALL_LIBDIR=lib -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_APPS=OFF -DBUILD_DEC=OFF -DBUILD_TESTING=OFF -DENABLE_AVX512=OFF \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" -DCMAKE_SYSTEM_PROCESSOR="$ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 "-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local"
  step "svt-$ARCH-make" cmake --build "$SRC/_build" -j "$JOBS"
  step "svt-$ARCH-install" cmake --install "$SRC/_build"
}

build_ffmpeg_arch() {
  unpack ffmpeg "$T_FFMPEG" "$WORK/src-ffmpeg-$ARCH"
  ffmpeg_flags "$ARCH" "$PFX"
  step "ffmpeg-$ARCH-configure" in_dir "$SRC" ./configure "${FF_FLAGS[@]}"
  step "ffmpeg-$ARCH-make" in_dir "$SRC" make -j"$JOBS"
  mkdir -p "$WORK/out-$ARCH"
  cp "$SRC/ffmpeg" "$WORK/out-$ARCH/"
  unpack ffmpeg "$T_FFMPEG" "$WORK/src-ffprobe-$ARCH"
  ffprobe_flags "$ARCH"
  step "ffprobe-$ARCH-configure" in_dir "$SRC" ./configure "${FFPROBE_FLAGS[@]}"
  step "ffprobe-$ARCH-make" in_dir "$SRC" make -j"$JOBS" ffprobe
  cp "$SRC/ffprobe" "$WORK/out-$ARCH/"
}

build_ffmpeg() { # outdir
  local out=$1 a d="$WORK/lic"
  T_FFMPEG="$(fetch "$FFMPEG_URL" "$FFMPEG_SHA" ffmpeg-$FFMPEG_VER.tar.xz)"
  T_LAME="$(fetch "$LAME_URL" "$LAME_SHA" lame-$LAME_VER.tar.gz)"
  T_OPUS="$(fetch "$OPUS_URL" "$OPUS_SHA" opus-$OPUS_VER.tar.gz)"
  T_VPX="$(fetch "$VPX_URL" "$VPX_SHA" libvpx-$VPX_VER.tar.gz)"
  T_SVT="$(fetch "$SVT_URL" "$SVT_SHA" svt-av1-$SVT_VER.tar.gz)"
  for a in $ARCHES; do
    say "ffmpeg stack: $a"
    use_arch "$a"
    build_lame; build_opus; build_vpx; build_svt; build_ffmpeg_arch
  done
  make_universal "$out/ffmpeg"  "$WORK/out-arm64/ffmpeg"  "$WORK/out-x86_64/ffmpeg"
  make_universal "$out/ffprobe" "$WORK/out-arm64/ffprobe" "$WORK/out-x86_64/ffprobe"
  # Licence texts come from the pinned tarballs themselves.
  unpack_nopatch "$T_FFMPEG" "$d/ffmpeg"
  write_license "$out/LICENSES/ffmpeg.txt" ffmpeg "$FFMPEG_VER" "$FFMPEG_URL" "$FFMPEG_SHA" "$SRC" COPYING.LGPLv2.1 LICENSE.md
  unpack_nopatch "$T_LAME" "$d/lame"
  write_license "$out/LICENSES/lame.txt" lame "$LAME_VER" "$LAME_URL" "$LAME_SHA" "$SRC" COPYING LICENSE
  unpack_nopatch "$T_OPUS" "$d/opus"
  write_license "$out/LICENSES/opus.txt" opus "$OPUS_VER" "$OPUS_URL" "$OPUS_SHA" "$SRC" COPYING
  unpack_nopatch "$T_VPX" "$d/vpx"
  write_license "$out/LICENSES/libvpx.txt" libvpx "$VPX_VER" "$VPX_URL" "$VPX_SHA" "$SRC" LICENSE PATENTS
  unpack_nopatch "$T_SVT" "$d/svt"
  write_license "$out/LICENSES/svt-av1.txt" svt-av1 "$SVT_VER" "$SVT_URL" "$SVT_SHA" "$SRC" LICENSE.md LICENSE-BSD2.md PATENTS.md
}
#<< RECIPE ffmpeg

# -------------------------------------------------------- ghostscript
#>> RECIPE gs
# Only the devices L'Esclop runs (pdfwrite; txtwrite and png for page text and previews) and no
# printer, IJS, TIFF, URF or contributed drivers. The Resource tree (fonts, CMaps) stays
# compiled in.
GS_DRIVERS="pdfwrite,txtwrite,png16m,pngalpha,pnggray"
GS_FLAGS="--without-x --disable-cups --disable-gtk --disable-dbus --disable-fontconfig --without-libidn --without-tesseract --without-libpaper --without-ijs --without-libtiff --without-urf --without-so --without-pdftoraster --disable-contrib --with-drivers=$GS_DRIVERS --enable-compile-inits"

# Fonts compiled into gs: the 14 standard PDF fonts (URW equivalents), which PDFs may use
# without embedding. The other 21 URW fonts (Bookman, Palatino, New Century Schoolbook, Avant
# Garde, Zapf Chancery, Helvetica Narrow) go, and Fontmap.GS sends their names to the kept font
# of the same family and style (GS_FONT_SUBST), so a PDF naming one of them without embedding
# it keeps its text with a close serif or sans. The CMaps and the CJK fallback (CIDFSubst)
# stay, or non-embedded CJK text would vanish.
GS_FONT_SUBST="C059-Roman:NimbusRoman-Regular C059-Bold:NimbusRoman-Bold C059-Italic:NimbusRoman-Italic C059-BdIta:NimbusRoman-BoldItalic P052-Roman:NimbusRoman-Regular P052-Bold:NimbusRoman-Bold P052-Italic:NimbusRoman-Italic P052-BoldItalic:NimbusRoman-BoldItalic URWBookman-Light:NimbusRoman-Regular URWBookman-Demi:NimbusRoman-Bold URWBookman-LightItalic:NimbusRoman-Italic URWBookman-DemiItalic:NimbusRoman-BoldItalic Z003-MediumItalic:NimbusRoman-Italic URWGothic-Book:NimbusSans-Regular URWGothic-Demi:NimbusSans-Bold URWGothic-BookOblique:NimbusSans-Italic URWGothic-DemiOblique:NimbusSans-BoldItalic NimbusSansNarrow-Regular:NimbusSans-Regular NimbusSansNarrow-Bold:NimbusSans-Bold NimbusSansNarrow-Oblique:NimbusSans-Italic NimbusSansNarrow-BoldOblique:NimbusSans-BoldItalic"
GS_FONTS="NimbusSans-Regular NimbusSans-Bold NimbusSans-Italic NimbusSans-BoldItalic NimbusRoman-Regular NimbusRoman-Bold NimbusRoman-Italic NimbusRoman-BoldItalic NimbusMonoPS-Regular NimbusMonoPS-Bold NimbusMonoPS-Italic NimbusMonoPS-BoldItalic StandardSymbolsPS D050000L"

build_gs_arch() {
  unpack ghostscript "$T_GS" "$WORK/src-gs-$ARCH"
  local f
  for f in "$SRC"/Resource/Font/*; do
    case " $GS_FONTS " in *" $(basename "$f") "*) ;; *) rm -f "$f";; esac
  done
  # psi/psromfs.mak lists every font as a dependency of the compiled-in file system.
  awk -v keep=" $GS_FONTS " 'match($0, /Font\$\(D\)[A-Za-z0-9-]+/) {
      name = substr($0, RSTART + 8, RLENGTH - 8); if (index(keep, " " name " ") == 0) next }
    { print }' "$SRC/psi/psromfs.mak" > "$SRC/psi/psromfs.mak.new" && mv "$SRC/psi/psromfs.mak.new" "$SRC/psi/psromfs.mak"
  local pair sedargs=()
  for pair in $GS_FONT_SUBST; do
    sedargs+=(-e "s#/${pair%%:*}\([[:space:];]\)#/${pair#*:}\1#g")
  done
  sed "${sedargs[@]}" "$SRC/Resource/Init/Fontmap.GS" > "$SRC/Resource/Init/Fontmap.GS.new" &&
    mv "$SRC/Resource/Init/Fontmap.GS.new" "$SRC/Resource/Init/Fontmap.GS"
  # Ghostscript builds and runs helper programs (genarch, mkromfs...). The
  # Command Line Tools are arm64-only, so the x86_64 slice is cross-compiled:
  # helpers are built for the host (CCAUX) and arch.h is reused from the arm64
  # build (both targets are little-endian LP64 with identical type sizes).
  local extra=""
  if [ "$ARCH" != arm64 ]; then
    extra="--host=$HOST_TRIPLE --with-arch_h=$WORK/arm64-arch.h"
    export CCAUX="clang -arch arm64" CFLAGSAUX="-O2 -mmacosx-version-min=14.0"
  fi
  step "gs-$ARCH-configure" in_dir "$SRC" ./configure $GS_FLAGS $extra
  step "gs-$ARCH-make" in_dir "$SRC" make -j"$JOBS"
  mkdir -p "$WORK/out-$ARCH"
  cp "$SRC/bin/gs" "$WORK/out-$ARCH/gs"
  [ "$ARCH" != arm64 ] || cp "$SRC/obj/arch.h" "$WORK/arm64-arch.h"
}

build_gs() { # outdir
  local out=$1 a
  T_GS="$(fetch "$GS_URL" "$GS_SHA" ghostscript-$GS_VER.tar.xz)"
  for a in $ARCHES; do
    say "ghostscript: $a"
    use_arch "$a"
    build_gs_arch
  done
  make_universal "$out/gs" "$WORK/out-arm64/gs" "$WORK/out-x86_64/gs"
  unpack_nopatch "$T_GS" "$WORK/lic/gs"
  write_license "$out/LICENSES/ghostscript.txt" ghostscript "$GS_VER" "$GS_URL" "$GS_SHA" "$SRC" LICENSE \
    freetype/docs/FTL.TXT jpeg/README libpng/LICENSE zlib/README jbig2dec/LICENSE openjpeg/LICENSE \
    lcms2mt/COPYING brotli/LICENSE
}
#<< RECIPE gs

# ----------------------------------------------------------- gifsicle
#>> RECIPE gifsicle
GIFSICLE_FLAGS="--disable-gifview --disable-gifdiff"

build_gifsicle_arch() {
  unpack gifsicle "$T_GIFSICLE" "$WORK/src-gifsicle-$ARCH"
  step "gifsicle-$ARCH-configure" in_dir "$SRC" ./configure --host="$HOST_TRIPLE" $GIFSICLE_FLAGS
  step "gifsicle-$ARCH-make" in_dir "$SRC" make -j"$JOBS"
  mkdir -p "$WORK/out-$ARCH"
  cp "$SRC/src/gifsicle" "$WORK/out-$ARCH/gifsicle"
}

build_gifsicle() { # outdir
  local out=$1 a
  T_GIFSICLE="$(fetch "$GIFSICLE_URL" "$GIFSICLE_SHA" gifsicle-$GIFSICLE_VER.tar.gz)"
  for a in $ARCHES; do
    say "gifsicle: $a"
    use_arch "$a"
    build_gifsicle_arch
  done
  make_universal "$out/gifsicle" "$WORK/out-arm64/gifsicle" "$WORK/out-x86_64/gifsicle"
  unpack_nopatch "$T_GIFSICLE" "$WORK/lic/gifsicle"
  write_license "$out/LICENSES/gifsicle.txt" gifsicle "$GIFSICLE_VER" "$GIFSICLE_URL" "$GIFSICLE_SHA" "$SRC" COPYING
}
#<< RECIPE gifsicle

# ---------------------------------------------------- group bookkeeping
group_tools() { case "$1" in ffmpeg) echo "ffmpeg ffprobe";; gs) echo gs;; gifsicle) echo gifsicle;; esac; }
group_patch_dirs() { case "$1" in
  ffmpeg) echo "ffmpeg lame opus libvpx svt-av1";; gs) echo ghostscript;; gifsicle) echo gifsicle;; esac; }
group_pins() { case "$1" in
  ffmpeg) echo "$FFMPEG_SHA $LAME_SHA $OPUS_SHA $VPX_SHA $SVT_SHA";;
  gs) echo "$GS_SHA";; gifsicle) echo "$GIFSICLE_SHA";; esac; }

recipe_text() { sed -n "/^#>> RECIPE $1\$/,/^#<< RECIPE $1\$/p" "$SELF"; }

# Cache key: pinned hashes + patch contents + the build recipe itself.
group_key() {
  local g=$1 d p
  {
    group_pins "$g"
    for d in $(group_patch_dirs "$g"); do
      for p in "$PATCHES/$d"/*.patch; do
        if [ -f "$p" ]; then echo "$d/$(basename "$p")"; cat "$p"; fi
      done
    done
    recipe_text common; recipe_text "$g"
  } | shasum -a 256 | cut -c1-16
}

install_group() { # group cachedir
  local g=$1 c=$2 t
  mkdir -p "$BIN/LICENSES"
  for t in $(group_tools "$g"); do cp "$c/$t" "$BIN/$t"; done
  cp "$c"/LICENSES/*.txt "$BIN/LICENSES/"
}

build_group() {
  local g=$1 key cdir tmp
  key="$(group_key "$g")"; cdir="$CACHE/$g-$key"
  if [ "$FORCE" = 0 ] && [ -d "$cdir" ]; then
    say "$g: cache hit ($key), reinstalling"
  else
    say "$g: building (key $key)"
    tmp="$WORK/outcache-$g"; rm -rf "$tmp"; mkdir -p "$tmp/LICENSES"
    "build_$g" "$tmp"
    rm -rf "$CACHE/$g-"*; mv "$tmp" "$cdir"
  fi
  install_group "$g" "$cdir"
}

# -------------------------------------------------------- THIRD_PARTY.md
gen_third_party() {
  local flags="" pflags="" f
  ffmpeg_flags "<arch>" "<prefix>"
  for f in "${FF_FLAGS[@]}"; do
    case "$f" in *" "*) flags="$flags \"$f\"";; *) flags="$flags $f";; esac
  done
  ffprobe_flags "<arch>"
  for f in "${FFPROBE_FLAGS[@]}"; do
    case "$f" in *" "*) pflags="$pflags \"$f\"";; *) pflags="$pflags $f";; esac
  done
  cat > "$THIRD_PARTY" <<EOF
# Third-party software bundled with esclop

Generated by \`Scripts/build-tools.sh\`; do not edit by hand. The tools below are
built from the pinned source tarballs listed here and shipped as separate
executables. esclop starts them as child processes and never links against
them. Licence texts are written to \`Binaries/LICENSES/\` by the build script.

| Component | Ships as | Version | Licence (SPDX) | Source | SHA-256 |
| --- | --- | --- | --- | --- | --- |
| FFmpeg | \`ffmpeg\`, \`ffprobe\` | $FFMPEG_VER | LGPL-2.1-or-later | $FFMPEG_URL | $FFMPEG_SHA |
| LAME (libmp3lame) | static in \`ffmpeg\` | $LAME_VER | LGPL-2.0-or-later | $LAME_URL | $LAME_SHA |
| Opus (libopus) | static in \`ffmpeg\` | $OPUS_VER | BSD-3-Clause | $OPUS_URL | $OPUS_SHA |
| libvpx | static in \`ffmpeg\` | $VPX_VER | BSD-3-Clause | $VPX_URL | $VPX_SHA |
| SVT-AV1 | static in \`ffmpeg\` | $SVT_VER | BSD-3-Clause-Clear | $SVT_URL | $SVT_SHA |
| Ghostscript | \`gs\` | $GS_VER | AGPL-3.0-or-later | $GS_URL | $GS_SHA |
| gifsicle | \`gifsicle\` | $GIFSICLE_VER | GPL-2.0-only | $GIFSICLE_URL | $GIFSICLE_SHA |

## How each tool is used

- **ffmpeg / ffprobe**: separate processes, LGPL configuration (no \`--enable-gpl\`,
  no \`--enable-nonfree\`, no x264/x265, no network protocols). Apple frameworks
  (VideoToolbox, AudioToolbox) are used through the system. libmp3lame is LGPL
  and statically linked into the ffmpeg executables, so the corresponding
  source (the pinned tarballs above and any patches under \`Binaries/patches/\`)
  must be made available with the application.
- **gs**: separate process, AGPL-3.0-or-later. Statically contains the
  third-party libraries bundled in the Ghostscript tarball (FreeType 2.14.2,
  libpng 1.6.58, zlib 1.3.2, IJG JPEG 10, jbig2dec 0.20, OpenJPEG 2.5.x,
  Brotli 1.2.0, lcms2mt), each under its own licence; their
  licence files are appended to \`Binaries/LICENSES/ghostscript.txt\`.
  Configure flags: \`$GS_FLAGS\`.
- **gifsicle**: separate process, GPL-2.0-only. It is only ever executed, never
  linked into esclop. Configure flags: \`$GIFSICLE_FLAGS\`.

## ffmpeg configure line

Per architecture (arm64 and x86_64 are built separately, then merged with
\`lipo\`; the x86_64 build adds \`--enable-cross-compile --x86asmexe=nasm\`):

\`\`\`
./configure$flags
\`\`\`

ffprobe is built from a second, probe-only configuration of the same tarball (no
encoders, filters or external libraries):

\`\`\`
./configure$pflags
\`\`\`
EOF
}

# ------------------------------------------------------------ verify
REQUIRED_ENCODERS="h264_videotoolbox hevc_videotoolbox prores_videotoolbox libsvtav1 libvpx-vp9 libopus libmp3lame aac aac_at alac_at flac pcm_s16le pcm_s16be pcm_s24le adpcm_ima_wav png mjpeg gif rawvideo wrapped_avframe"
VERIFY_FAIL=0
vfail() { echo "  FAIL: $*" >&2; VERIFY_FAIL=1; }

# Run a tool the way the app will: empty environment, from Binaries/.
runtool() { (cd "$BIN" && env -i PATH=/usr/bin:/bin "./$@"); }

version_cmd() { case "$1" in ffmpeg|ffprobe) echo "-version";; *) echo "--version";; esac; }

verify_tool() { # tool
  local t=$1 p="$BIN/$1" ver archs bad size
  [ -x "$p" ] || { vfail "$t missing"; return; }
  ver="$(runtool "$t" $(version_cmd "$t") 2>&1 | head -1)" || vfail "$t version command failed"
  archs="$(lipo -archs "$p" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')"
  [ "$archs" = "arm64 x86_64" ] || vfail "$t archs are '$archs'"
  bad="$("$ROOT/Scripts/foreign-dylibs.sh" "$p" | tr '\t\n' ': ')" || vfail "$t is not a Mach-O file"
  [ -z "$bad" ] || vfail "$t links non-system libraries: $bad"
  if arch -x86_64 /usr/bin/true 2>/dev/null; then
    (cd "$BIN" && env -i PATH=/usr/bin:/bin arch -x86_64 "./$t" $(version_cmd "$t") >/dev/null 2>&1) \
      || vfail "$t x86_64 slice does not run"
  fi
  size="$(du -h "$p" | cut -f1)"
  printf '  %-9s %-6s %-14s %s\n' "$t" "$size" "$archs" "$ver"
}

verify_ffmpeg_extras() {
  local enc names conf prot tmp e src aud
  enc="$(runtool ffmpeg -hide_banner -encoders 2>&1)"
  names="$(awk '{print $2}' <<<"$enc")"
  for e in $REQUIRED_ENCODERS; do
    grep -qx "$e" <<<"$names" || vfail "ffmpeg lacks encoder $e"
  done
  for e in libx264 libx265; do
    if grep -qx "$e" <<<"$names"; then vfail "ffmpeg has forbidden encoder $e"; fi
  done
  conf="$(runtool ffmpeg -hide_banner -buildconf 2>&1)"
  if grep -qE -- '--enable-(gpl|nonfree|version3)' <<<"$conf"; then vfail "ffmpeg build is GPL/nonfree"; fi
  prot="$(runtool ffmpeg -hide_banner -protocols 2>&1)"
  if grep -qxE '[[:space:]]*(http|https|tcp|udp|tls|rtmp|rtp|srtp)' <<<"$prot"; then vfail "ffmpeg has network protocols"; fi
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/esclop-smoke.XXXXXX")"
  src="-f lavfi -i testsrc2=d=1:s=320x240"; aud="-f lavfi -i sine=d=1"
  # smoke LABEL OUTFILE ffmpeg-args...
  smoke() {
    local l=$1 o=$2; shift 2
    if runtool ffmpeg -hide_banner -loglevel error -y "$@" "$tmp/$o" >"$tmp/log" 2>&1 && [ -s "$tmp/$o" ]; then
      echo "  smoke ok: $l"
    else
      vfail "smoke encode failed: $l ($(head -c 200 "$tmp/log" | tr '\n' ' '))"
    fi
  }
  if runtool ffmpeg -hide_banner -loglevel error -y $src -c:v h264_videotoolbox -f mp4 "$tmp/vt.mp4" >"$tmp/log" 2>&1 && [ -s "$tmp/vt.mp4" ]; then
    echo "  smoke ok: h264_videotoolbox"
  else
    echo "  NOTE: VideoToolbox smoke encode unavailable here: $(head -c 160 "$tmp/log" | tr '\n' ' ')"
  fi
  smoke "libsvtav1 mp4" a.mp4 $src -c:v libsvtav1 -preset 10
  smoke "libvpx-vp9 + libopus webm, scale/fps/aformat" b.webm $src $aud -vf scale=160:-2,fps=10,format=yuv420p -af aresample=48000,aformat=sample_fmts=fltp -c:v libvpx-vp9 -b:v 200k -c:a libopus
  smoke "libmp3lame" c.mp3 $aud -c:a libmp3lame
  smoke "gif palettegen/paletteuse" d.gif $src -filter_complex "split[a][b];[a]palettegen[p];[b][p]paletteuse"
  smoke "aac_at + loudnorm" e.m4a $aud -af loudnorm,aresample=48000 -c:a aac_at
  # ffprobe is its own build: it must still read what MediaProbe.swift needs.
  if [ -s "$tmp/b.webm" ] && runtool ffprobe -v error -print_format json -show_format -show_streams "$tmp/b.webm" > "$tmp/probe.json" 2>&1 \
    && grep -q '"codec_name": "vp9"' "$tmp/probe.json" && grep -q '"codec_name": "opus"' "$tmp/probe.json" \
    && grep -q '"pix_fmt": "yuv420p"' "$tmp/probe.json" && grep -q '"duration"' "$tmp/probe.json"; then
    echo "  probe ok: ffprobe reads codecs, pixel format and duration"
  else
    vfail "ffprobe JSON lacks codec, pixel format or duration ($(head -c 200 "$tmp/probe.json" | tr '\n' ' '))"
  fi
  rm -rf "$tmp"
}

verify_gs() {
  if runtool gs -dSAFER -q -dNOPAUSE -dBATCH -sDEVICE=pdfwrite -o /dev/null -c showpage >/dev/null 2>&1; then
    echo "  smoke ok: gs pdfwrite"
  else
    vfail "gs pdfwrite smoke test failed"
  fi
}

verify_all() { # groups...
  local g t
  VERIFY_FAIL=0
  say "verify"
  for g in "$@"; do
    for t in $(group_tools "$g"); do verify_tool "$t"; done
    case "$g" in ffmpeg) verify_ffmpeg_extras;; gs) verify_gs;; esac
  done
  [ "$VERIFY_FAIL" = 0 ] || die "verification failed"
  echo "verification passed"
}

# -------------------------------------------------------------- main
FORCE=0; VERIFY_ONLY=0; DO_VERIFY=1; SEL=""
usage() { sed -n '4,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1;;
    --verify) VERIFY_ONLY=1;;
    --no-verify) DO_VERIFY=0;;
    -h|--help) usage;;
    ffmpeg|ffprobe) SEL="$SEL ffmpeg";;
    gs|gifsicle) SEL="$SEL $arg";;
    *) die "unknown argument: $arg";;
  esac
done
[ -n "$SEL" ] || SEL="ffmpeg gs gifsicle"
SEL="$(echo $SEL | tr ' ' '\n' | sort -u | tr '\n' ' ')"

[ "$(uname -s)" = Darwin ] || die "macOS only"
mkdir -p "$BIN" "$CACHE"
START=$SECONDS

if [ "$VERIFY_ONLY" = 1 ]; then
  verify_all $SEL
  exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/esclop-build.XXXXXX")"
# ESCLOP_KEEP_WORK=1 keeps the build tree (sources, prefixes, logs) for inspection.
if [ "${ESCLOP_KEEP_WORK:-0}" = 1 ]; then
  trap 'echo "build tree kept in $WORK" >&2' EXIT
else
  trap 'rm -rf "$WORK"' EXIT
fi
LOGS="$WORK/logs"; mkdir -p "$LOGS"
# Build tools (never libraries) are linked into a private bin dir.
TOOLBIN="$WORK/tools"; mkdir -p "$TOOLBIN"
need=""
for t in nasm cmake pkg-config; do
  p="$(command -v "$t" || true)"
  if [ -z "$p" ]; then need="$need $t"; else ln -s "$p" "$TOOLBIN/$t"; fi
done
command -v clang >/dev/null || die "clang not found (xcode-select --install)"
[ -z "$need" ] || die "missing build tools:$need (brew install$need)"

for g in $SEL; do build_group "$g"; done
gen_third_party
echo "built/installed in $((SECONDS - START))s"
if [ "$DO_VERIFY" = 1 ]; then verify_all $SEL; fi
