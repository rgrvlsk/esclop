#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Runs `swift test`. With only the Command Line Tools installed, the Swift Testing macro plugin
# is not found by default, so it is loaded explicitly. With Xcode selected, plain `swift test` works.
#
# ESCLOP_TEST_TIMEOUT=<seconds> adds a watchdog. When the tests outlive it, the script samples
# the stacks of the test process and kills it (only it: `swift test` then prints the output it
# was still holding and writes Swift Testing's event stream), names the tests that started and
# never finished, and exits 124. CI sets it so a hang fails in minutes, with names and stacks.
set -eu
cd "$(dirname "$0")/.."
# The MCP conformance test drives the real `esclop mcp serve` binary over stdio.
swift build --product esclop >&2
ESCLOP_TEST_BINARY="$(swift build --show-bin-path)/esclop"
export ESCLOP_TEST_BINARY
# The app's copy follows the system language; tests check the English base unless asked.
ESCLOP_LANGUAGE="${ESCLOP_LANGUAGE:-en}"
export ESCLOP_LANGUAGE
DEV_DIR="$(xcode-select -p)"
PLUGIN="$DEV_DIR/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [ -f "$PLUGIN" ] && ! [ -d "$DEV_DIR/../Applications" ]; then
    set -- -Xswiftc -load-plugin-library -Xswiftc "$PLUGIN" "$@"
fi
if [ -z "${ESCLOP_TEST_TIMEOUT:-}" ]; then
    exec swift test "$@"
fi

limit=$ESCLOP_TEST_TIMEOUT
work="$(mktemp -d)"
events="$work/events.jsonl"
# The process that runs the tests, under `swift test` (Swift Testing's helper or xctest).
runner='swiftpm-testing-helper|[.]xctest/'
swift test "$@" --event-stream-output-path "$events" --event-stream-version 0 &
pid=$!
start=
while kill -0 "$pid" 2>/dev/null; do
    # The clock starts once a test process is up, so the build inside `swift test` is not counted.
    if [ -z "$start" ] && pgrep -f "$runner" > /dev/null; then start=$(date +%s); fi
    if [ -n "$start" ] && [ $(( $(date +%s) - start )) -ge "$limit" ]; then
        for p in $(pgrep -f "$runner" || true); do
            echo "--- stacks of the test process $p, frames from this package:" >&2
            sample "$p" 2 -mayDie 2>/dev/null | sed -n '/^Call graph:/,/^Total number in stack/p' \
                | grep -E 'Thread_|[Ee]sclop|Tests[.]swift|Harness|Fakes|Support' | cut -c1-220 | head -300 >&2 || true
        done
        pkill -9 -f "$runner" || true
        # `swift test` reports the crash, flushes the output and writes the event stream.
        waited=0
        while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 30 ]; do sleep 1; waited=$((waited + 1)); done
        kill -9 "$pid" 2>/dev/null || true
        ids() { grep "\"kind\":\"$1\"" "$events" 2>/dev/null | sed -n 's/.*"testID":"\([^"]*\)".*/\1/p' | sed 's#\\/#/#g' | sort; }
        ids testStarted > "$work/started"
        ids testEnded > "$work/ended"
        echo "::error::tests still running after ${limit} s. Started and never finished:" >&2
        comm -23 "$work/started" "$work/ended" | sed 's/^/  /' >&2
        exit 124
    fi
    sleep 1
done
wait "$pid"
