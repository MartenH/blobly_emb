#!/usr/bin/env bash
# Integration test for a blobly example: run its built app on a (v)CAN bus and
# drive/assert it with blobly_net's headless Lua runner (which knows the DBC).
#
#   BLOBLY_NET=/path/to/blobly_net  scripts/integration-test.sh examples/overspeed
#
# The example must provide test/vcan.yml (blobly_net project pointing at $IFACE,
# no simulation — the app IS the ECU) and one or more test/*.lua scripts. A script that
# declares its own project (`-- @project <file>` in its leading comment — e.g. one where
# blobly_net simulates a peer ECU) runs against that project, in an invocation of its own.
set -euo pipefail

EX="${1:?usage: integration-test.sh <example-dir>}"
EX="$(cd "$EX" && pwd)"
IFACE="${IFACE:-vcan0}"
: "${BLOBLY_NET:?set BLOBLY_NET=/path/to/blobly_net (https://github.com/MartenH/blobly_net)}"

[ -x "$EX/bin/app" ] || { echo "build the example first (make all in $EX)"; exit 1; }
ip link show "$IFACE" >/dev/null 2>&1 || { echo "bring up $IFACE: sudo make vcan"; exit 1; }

# Run the example ECU in the background; always clean it up.
"$EX/bin/app" "$IFACE" >/dev/null 2>&1 &
app=$!
trap 'kill $app 2>/dev/null || true' EXIT
sleep 0.6

# blobly_net drives + asserts; its runner exits non-zero if any test fails.
cd "$EX"
# Which scripts declare their own project: the RUNNER's rule (blobly_net
# modules/script/project_decl.v, declaration_in), mirrored — the leading comment is every line
# up to the first non-blank line that is not a `--` comment; a declaration is a comment line
# whose text after its dashes starts with @project. One awk pass, so no pipe to lose a match to.
declares_project() {
    awk '{ t = $0; gsub(/^[ \t]+|[ \t]+$/, "", t)
           if (t == "") next
           if (substr(t, 1, 2) != "--") exit
           sub(/^-+[ \t]*/, "", t)
           if (t ~ /^@project/) { found = 1; exit } }
         END { exit !found }' "$1"
}
# Built once: `v run` compiles the runner on every call, and each declared script is a call.
runner="$(mktemp -d)/run"
trap 'kill $app 2>/dev/null || true; rm -rf "$(dirname "$runner")"' EXIT
v -enable-globals -path "@vlib|@vmodules|$BLOBLY_NET/modules" -o "$runner" "$BLOBLY_NET/cmd/script/run.v"
plain=() declared=()
for t in test/*.lua; do
    if declares_project "$t"; then declared+=("$t"); else plain+=("$t"); fi
done
status=0
if [ ${#plain[@]} -gt 0 ]; then "$runner" --project test/vcan.yml "${plain[@]}" || status=1; fi
for t in "${declared[@]}"; do "$runner" "$t" || status=1; done
exit $status
