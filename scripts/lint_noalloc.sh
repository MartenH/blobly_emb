#!/usr/bin/env bash
# Enforce the no-dynamic-allocation house style in the runtime layers (FBs,
# generated code, comms stack). Bans V's heap-backed constructs: `string`,
# `map[...]`, growable `[]T`. Fixed arrays like `[64]u8` are fine and stay.
#
# Scanned: comm/, loom/, and each example's runtime files. Excluded: each
# example's main.v (the entry/bus-bridge — init-time heap like osal/driver is OK)
# and *_test.v.
set -euo pipefail

dirs=("comm" "loom" "examples")
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
	done < <(find "$d" -name '*.v' -not -name 'main.v' -not -name '*_test.v' -print0)
done

# Partition isolation: only an example's main.v (the IO/bus bridge) may touch a
# driver. FB / signal / generated files must reach the bus only through signals.
if grep -rnE '^\s*import\s+driver' examples/ --include='*.v' 2>/dev/null | grep -v '/main\.v:'; then
	echo "  ^ only an example's main.v may import a driver (FBs use signals)"
	fail=1
fi

if [ "$fail" -ne 0 ]; then
	echo "no-alloc lint FAILED"
	exit 1
fi
echo "no-alloc + isolation lint passed"
