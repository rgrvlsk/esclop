#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Package the exact SwiftPM revisions as Git bundles, without local Git configuration.
# Run after swift build. Usage: Scripts/swift-sources.sh OUTDIR
# shellcheck disable=SC2016 # Generated scripts expand these variables when the recipient runs them.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "${1:?usage: Scripts/swift-sources.sh OUTDIR}"
OUT="$(cd "$1" && pwd)"
RESOLVED="$ROOT/Package.resolved"
cp "$RESOLVED" "$OUT/"
printf '#!/usr/bin/env bash\nset -euo pipefail\nvendor="$(cd "$(dirname "$0")" && pwd)"\n' > "$OUT/mirrors.sh"
i=0
while id="$(plutil -extract "pins.$i.identity" raw -o - "$RESOLVED" 2>/dev/null)"; do
  revision="$(plutil -extract "pins.$i.state.revision" raw -o - "$RESOLVED")"
  url="$(plutil -extract "pins.$i.location" raw -o - "$RESOLVED")"
  checkout="${ESCLOP_SCRATCH_PATH:-$ROOT/.build}/checkouts/$id"
  [ "$(git -C "$checkout" rev-parse HEAD)" = "$revision" ] || { echo "swift-sources: $id differs from Package.resolved" >&2; exit 1; }
  [ -z "$(git -C "$checkout" status --porcelain)" ] || { echo "swift-sources: $id has local changes" >&2; exit 1; }
  refs=(HEAD)
  while IFS= read -r tag; do
    [ -z "$tag" ] || refs+=("refs/tags/$tag")
  done < <(git -C "$checkout" tag --points-at HEAD)
  git -C "$checkout" bundle create "$OUT/$id.bundle" "${refs[@]}"
  printf 'git clone --bare "$vendor/%s.bundle" "$vendor/%s.git"\n' "$id" "$id" >> "$OUT/mirrors.sh"
  printf 'swift package config set-mirror --original %q --mirror "file://$vendor/%s.git"\n' "$url" "$id" >> "$OUT/mirrors.sh"
  i=$((i + 1))
done
[ "$i" -gt 0 ] || { echo "swift-sources: no resolved packages" >&2; exit 1; }
cat > "$OUT/README.txt" <<'EOF'
SwiftPM dependency sources at the revisions in Package.resolved. Each Git bundle contains
the upstream commit and its history. Local Git configuration and working files are excluded.

For an offline build, extract this archive next to the repository source archive. From the
repository root, run bash ../esclop-swift-<version>-vendor/mirrors.sh once, then swift build.
The script creates local bare mirrors and configures SwiftPM to use them. Use the Swift
toolchain and other prerequisites documented in the repository. Keep Package.resolved.
EOF
echo "swift-sources: $i packages" >&2
