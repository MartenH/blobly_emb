#!/usr/bin/env bash
# Enforce the no-dynamic-allocation house style in the layers app developers and
# the comms stack live in. Bans V's heap-backed constructs: `string`, `map[...]`,
# and growable `[]T` slices. Fixed arrays like `[64]u8` are fine and stay.
set -euo pipefail

# Strict runtime layers. tools/ is intentionally excluded (build-time heap is OK).
dirs=("app" "comm" "loom" "gen" "sig")
# string keyword | map literal/type | empty-bracket slice type []T
pattern='(\bstring\b|\bmap\[|\[\][A-Za-z_])'
fail=0

for d in "${dirs[@]}"; do
	[ -d "$d" ] || continue
	while IFS= read -r -d '' f; do
		if grep -nE "$pattern" "$f"; then
			echo "  ^ banned dynamic-allocation construct in $f"
			fail=1
		fi
	done < <(find "$d" -name '*.v' -not -name '*_test.v' -print0)
done

# Partition isolation: the App partition (app/) must never reach a driver
# directly — it talks only through ports/IOC. This is the software mirror of the
# MPU rule that an app partition has no access to the CAN peripheral.
if grep -rnE '^\s*import\s+driver' app/ 2>/dev/null; then
	echo "  ^ app must not import a driver directly (use ports / IOC)"
	fail=1
fi

if [ "$fail" -ne 0 ]; then
	echo "no-alloc lint FAILED"
	exit 1
fi
echo "no-alloc + partition-isolation lint passed"
