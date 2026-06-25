#!/usr/bin/env bash
# Integration test for a blobly example: run its built app on a (v)CAN bus and
# drive/assert it with cantester_v's headless Lua runner (which knows the DBC).
#
#   CANTESTER=/path/to/cantester_v  scripts/integration-test.sh examples/overspeed
#
# The example must provide test/vcan.yml (cantester project pointing at $IFACE,
# no simulation — the app IS the ECU) and one or more test/*.lua scripts.
set -euo pipefail

EX="${1:?usage: integration-test.sh <example-dir>}"
EX="$(cd "$EX" && pwd)"
IFACE="${IFACE:-vcan0}"
: "${CANTESTER:?set CANTESTER=/path/to/cantester_v (https://github.com/MartenH/cantester_v)}"

[ -x "$EX/bin/app" ] || { echo "build the example first (make all in $EX)"; exit 1; }
ip link show "$IFACE" >/dev/null 2>&1 || { echo "bring up $IFACE: sudo make vcan"; exit 1; }

# Run the example ECU in the background; always clean it up.
"$EX/bin/app" "$IFACE" >/dev/null 2>&1 &
app=$!
trap 'kill $app 2>/dev/null || true' EXIT
sleep 0.6

# cantester drives + asserts; its runner exits non-zero if any test fails.
cd "$EX"
v -enable-globals -path "@vlib|@vmodules|$CANTESTER/modules" \
    run "$CANTESTER/cmd/script/run.v" --project test/vcan.yml test/*.lua
