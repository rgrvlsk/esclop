#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Runs `swift test`. With only the Command Line Tools installed, the Swift Testing macro plugin
# is not found by default, so it is loaded explicitly. With Xcode selected, plain `swift test` works.
set -eu
cd "$(dirname "$0")/.."
# The MCP conformance test drives the real `esclop mcp serve` binary over stdio.
swift build --product esclop >&2
ESCLOP_TEST_BINARY="$(swift build --show-bin-path)/esclop"
export ESCLOP_TEST_BINARY
DEV_DIR="$(xcode-select -p)"
PLUGIN="$DEV_DIR/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [ -f "$PLUGIN" ] && ! [ -d "$DEV_DIR/../Applications" ]; then
    exec swift test -Xswiftc -load-plugin-library -Xswiftc "$PLUGIN" "$@"
fi
exec swift test "$@"
