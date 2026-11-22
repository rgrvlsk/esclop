#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Runs Scripts/test.sh's sweep of $TMPDIR/esclop-tests in a sandbox: a folder older than an hour
# goes; a fresh one (the current run's), loose files and folders outside esclop-tests stay.
set -eu
cd "$(dirname "$0")/.."
sweep="$(grep -E '^find .*/esclop-tests"' Scripts/test.sh)"
[ -n "$sweep" ] || { echo "test-sweep-check: no esclop-tests sweep in Scripts/test.sh" >&2; exit 1; }
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/test-sweep-check.XXXXXX")"
trap 'rm -rf "$sandbox"' EXIT
mkdir -p "$sandbox/esclop-tests/old-run/inner" "$sandbox/esclop-tests/this-run" "$sandbox/neighbour"
touch -t 202001010000 "$sandbox/esclop-tests/old-run" "$sandbox/neighbour"
TMPDIR="$sandbox" sh -c "$sweep"
failed=0
check() { if [ "$1" "$2" ]; then :; else echo "test-sweep-check: expected $1 $2" >&2; failed=1; fi; }
[ ! -e "$sandbox/esclop-tests/old-run" ] || { echo "test-sweep-check: the old folder stayed" >&2; failed=1; }
check -d "$sandbox/esclop-tests/this-run"
check -d "$sandbox/esclop-tests"
check -d "$sandbox/neighbour"
[ "$failed" = 0 ] && echo "test-sweep-check: passed"
exit "$failed"
