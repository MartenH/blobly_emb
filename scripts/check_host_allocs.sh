#!/usr/bin/env bash
# check_host_allocs.sh — the host twin of check_no_heap.sh (docs/no-alloc.md): compile every host
# example with -warn-about-allocs and fail on an allocation V3 reports in its GENERATED code
# (gen/), which runs for the program's life under -gc none. main.v is exempt (init-time strings).
# V3 allocates out of code that never looks like it does — a local whose address reaches a call it
# cannot see through moves to the heap — so reading the source says nothing; the compiler does.
#
#   V=<v>   the compiler (default: v on PATH)
set -uo pipefail
cd "$(dirname "$0")/.."
v=${V:-v}
tmp=$(mktemp -d) || exit 2
trap 'rm -rf "$tmp"' EXIT
fail=0
n_checked=0
# the directories CI's host-build loop builds: every example and every system node with a
# Makefile, a host one being one whose Makefiles name no ARM toolchain
for d in examples/*/ examples/*/nodes/*/; do
	ex=${d%/}
	[ -f "$ex/Makefile" ] && [ -f "$ex/main.v" ] && [ -d "$ex/gen" ] || continue
	# a cross example's gen/ is transpiled freestanding; check_no_heap.sh gates its image
	grep -rq arm-none-eabi "$ex" --include='Makefile*' && continue
	n_checked=$((n_checked + 1))
	if ! out=$("$v" -gc none -warn-about-allocs -path "@vlib|@vmodules|.|$ex" -o "$tmp/${ex//\//_}.c" "$ex" 2>&1); then
		echo "check_host_allocs: $ex does not compile:" >&2
		printf '%s\n' "$out" | tail -5 >&2
		fail=1
		continue
	fi
	hits=$(printf '%s\n' "$out" | grep -E "^$ex/gen/[^:]+:[0-9]+:[0-9]+: warning: allocation" || true)
	if [ -n "$hits" ]; then
		echo "check_host_allocs: $ex allocates in its generated code:" >&2
		printf '%s\n' "$hits" | sed 's/^/  /' >&2
		fail=1
	fi
done
[ "$n_checked" -gt 0 ] || { echo "check_host_allocs: no host example found" >&2; exit 2; }
[ $fail = 0 ] && echo "check_host_allocs: ok ($n_checked host examples)"
exit $fail
