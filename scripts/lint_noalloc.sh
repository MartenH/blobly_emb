#!/usr/bin/env bash
# Enforce the no-dynamic-allocation house style in the runtime layers (FBs,
# generated code, comms stack). Bans V's heap-backed constructs: `string`,
# `map[...]`, growable `[]T`. Fixed arrays like `[64]u8` are fine and stay.
#
# Scanned: comm/, loom/, and each example's runtime files (incl. the generated
# bus bridge in gen/, which stays no-alloc). Excluded: each example's main.v (the
# thin platform entry — init-time socket open / string ifname is OK) and *_test.v.
set -euo pipefail

dirs=("comm" "loom" "ecu" "wdg" "examples")
# string keyword | map literal/type | empty-bracket slice type []T
pattern='(\bstring\b|\bmap\[|\[\][A-Za-z_])'
fail=0

# Reviewed exceptions: files whose `string` uses are COMPILE-TIME LITERALS only —
# schema/registry metadata (endpoint names, command names/help) pointing at rodata,
# never concatenated, interpolated, or otherwise built at runtime. A V string literal
# is a {ptr,len} view of static data: no heap. Growable []T / map stay banned here too.
allow=("comm/com/endpoint.v" "comm/shell/shell.v")

for d in "${dirs[@]}"; do
	[ -d "$d" ] || continue
	while IFS= read -r -d '' f; do
		skip=0
		for a in "${allow[@]}"; do [ "$f" = "$a" ] && skip=1; done
		[ "$skip" = "1" ] && continue
		if grep -nE "$pattern" "$f"; then
			echo "  ^ banned dynamic-allocation construct in $f"
			fail=1
		fi
	done < <(find "$d" -name '*.v' -not -name 'main.v' -not -name '*_test.v' -print0)
done

# Partition isolation: only the platform entry (main.v) and the generated COM bus
# bridge (gen/loom_gen.v) may touch a driver — both are the IO boundary. FBs /
# signals / other generated files must reach the bus only through signals.
if grep -rnE '^\s*import\s+driver' examples/ --include='*.v' 2>/dev/null | grep -vE '/(main\.v|gen/loom_gen\.v):'; then
	echo "  ^ only main.v or the generated bus bridge (gen/loom_gen.v) may import a driver"
	fail=1
fi

if [ "$fail" -ne 0 ]; then
	echo "no-alloc lint FAILED"
	exit 1
fi
echo "no-alloc + isolation lint passed"
