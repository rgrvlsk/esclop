#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Prints the size of every Mach-O file in DIR, per architecture slice, and the totals, in MB
# (10^6 bytes). The payload target (docs/PLAN.md) is the universal total.
#
#   Scripts/payload-size.sh [DIR]      (default Binaries)
set -euo pipefail
DIR=${1:-Binaries}
printf '%-16s %10s %10s %10s\n' file arm64 x86_64 universal
ta=0; tx=0; tu=0
for f in "$DIR"/*; do
  [ -f "$f" ] || continue
  case "$(file -b --mime-type "$f")" in *mach*) ;; *) continue;; esac
  u=$(wc -c < "$f" | tr -d ' ')
  a=0; x=0
  if lipo -info "$f" 2>/dev/null | grep -q '^Non-fat'; then
    case "$(lipo -archs "$f")" in arm64) a=$u;; x86_64) x=$u;; esac
  else
    a=$(lipo -detailed_info "$f" | awk '$1 == "architecture" {c = ($2 == "arm64")} c && $1 == "size" {print $2; exit}')
    x=$(lipo -detailed_info "$f" | awk '$1 == "architecture" {c = ($2 == "x86_64")} c && $1 == "size" {print $2; exit}')
  fi
  printf '%-16s %10.2f %10.2f %10.2f\n' "$(basename "$f")" "$(echo "${a:-0}/1000000" | bc -l)" "$(echo "${x:-0}/1000000" | bc -l)" "$(echo "$u/1000000" | bc -l)"
  ta=$((ta + ${a:-0})); tx=$((tx + ${x:-0})); tu=$((tu + u))
done
printf '%-16s %10.2f %10.2f %10.2f\n' TOTAL "$(echo "$ta/1000000" | bc -l)" "$(echo "$tx/1000000" | bc -l)" "$(echo "$tu/1000000" | bc -l)"
