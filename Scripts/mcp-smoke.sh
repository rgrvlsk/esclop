#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Pipes a handful of JSON-RPC lines into `esclop mcp serve` and prints the replies, one per line.
# Manual check of the MCP server; the automated conformance test is in Tests/esclopTests.
#
#   Scripts/mcp-smoke.sh                 # builds, then talks to .build/debug/esclop
#   ESCLOP=/path/to/esclop Scripts/mcp-smoke.sh
#
# Runs against a temporary data folder and never through the app, so nothing real changes.
set -eu
cd "$(dirname "$0")/.."

if [ -z "${ESCLOP:-}" ]; then
    swift build --product esclop >&2
    ESCLOP="$(swift build --show-bin-path)/esclop"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The server handles requests concurrently, as MCP allows, so each line waits a moment for the
# previous reply; real clients wait for the response before a dependent call.
send() { printf '%s\n' "$1"; sleep 0.3; }

{
    send '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"mcp-smoke","version":"1"}}}'
    send '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    send '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
    send '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"esclop_status","arguments":{}}}'
    send '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"esclop_pipeline_write","arguments":{"name":"smoke","steps":"downscale(factor: 0.5) -> convert(to: webp)"}}}'
    send '{"jsonrpc":"2.0","id":5,"method":"resources/read","params":{"uri":"esclop://pipelines/smoke"}}'
    send '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"esclop_pipeline_delete","arguments":{"name":"smoke"}}}'
    send '{"jsonrpc":"2.0","id":7,"method":"prompts/get","params":{"name":"shrink_for","arguments":{"platform":"slack"}}}'
    send '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"esclop_convert","arguments":{"paths":["'"$WORK"'/missing.png"]}}}'
} | ESCLOP_SUPPORT_DIR="$WORK" ESCLOP_NO_APP=1 "$ESCLOP" mcp serve
