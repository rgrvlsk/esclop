#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Prints the body of a GitHub release: the CHANGELOG.md section of VERSION, then the list of
# artefacts and where the corresponding source is.
#
#   Scripts/release-notes.sh VERSION               the "## [VERSION]" section; fails when missing
#   Scripts/release-notes.sh --unreleased VERSION  the "## [Unreleased]" section (dry runs)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECTION=""
if [ "${1:-}" = --unreleased ]; then SECTION=Unreleased; shift; fi
VERSION=${1:?usage: Scripts/release-notes.sh [--unreleased] VERSION}
SECTION=${SECTION:-$VERSION}

# The lines after "## [SECTION]" up to the next "## [" heading or the link references.
body="$(awk -v s="$SECTION" '
  index($0, "## [" s "]") == 1 { on = 1; next }
  on && (/^## \[/ || /^\[[^]]+\]: /) { exit }
  on { print }' "$ROOT/CHANGELOG.md" | sed -e '/./,$!d' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')"
if [ -z "$body" ]; then
  echo "release-notes: CHANGELOG.md has no \"## [$SECTION]\" section, or it is empty" >&2
  exit 1
fi

cat <<EOF
$body

## Downloads

| File | What it is |
| --- | --- |
| \`esclop-$VERSION-cli.tar.gz\` | The \`esclop\` command line and MCP server with the bundled tools and every licence text (macOS 14+, Apple Silicon and Intel) |
| \`esclop-$VERSION-source.tar.zst\` | The source of this release (the repository at \`v$VERSION\`) |
| \`esclop-engine-$VERSION-vendor.tar.zst\` | The Rust crates \`esclop-engine\` is built from (\`cargo vendor\`) |
| \`esclop-swift-$VERSION-vendor.tar.zst\` | The Swift packages at their \`Package.resolved\` revisions, with offline build instructions |
| \`third-party-src-$VERSION.tar.zst\` | The upstream source tarballs, patches and build script of ffmpeg, Ghostscript and gifsicle |
| \`SHA256SUMS\` | SHA-256 of each file above |

L'Esclop is free software under the GNU GPL, version 3 or later. The four source archives
above are the complete corresponding source of the binaries in this release; licences and
versions of every bundled component are in \`THIRD_PARTY.md\` and \`LICENSES/\` inside the
archive.
EOF
