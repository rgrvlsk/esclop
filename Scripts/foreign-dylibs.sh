#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Lists the dynamic libraries a Mach-O file links from outside the system (/usr/lib and
# /System/Library), for every architecture of a universal file, as "ARCH<TAB>LIBRARY" lines.
# Prints nothing when the file links only system libraries.
#
# One implementation for Scripts/build-engine.sh, Scripts/build-tools.sh and
# Scripts/licence-gate.sh. `otool -L` prints a header line per architecture of a universal file
# ("FILE (architecture x86_64):"); taking every line but the first as a library once made the
# second header look like a foreign library named after the file. Headers end in ":" and
# library lines are indented, so only indented lines are read, with `-arch all` so that no
# slice is skipped whatever otool's default.
#
#   Scripts/foreign-dylibs.sh FILE
set -eu
[ $# -eq 1 ] || { echo "usage: Scripts/foreign-dylibs.sh FILE" >&2; exit 2; }
FILE=$1
# Not a Mach-O file must not read as "links nothing foreign" (otool exits 0 on it); lipo fails.
# lipo also names the architecture, which a thin file's otool header leaves out.
THIN_ARCH="$(lipo -archs "$FILE" 2>/dev/null)" || { echo "foreign-dylibs: $FILE is not a Mach-O file" >&2; exit 1; }
LIBS="$(otool -L -arch all "$FILE")" || { echo "foreign-dylibs: otool cannot read $FILE" >&2; exit 1; }
printf '%s\n' "$LIBS" | awk -v thin="$THIN_ARCH" '
    /^[^[:space:]].*:$/ {
        arch = thin
        if (match($0, /\(architecture [^)]*\):$/)) arch = substr($0, RSTART + 14, RLENGTH - 16)
        next
    }
    /^[[:space:]]/ { print arch "\t" $1 }
' | grep -v -E '	(/usr/lib/|/System/Library/)' || true
