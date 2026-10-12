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
for d in examples/*/; do
	n=$(basename "$d")
	[ -f "$d/main.v" ] && [ -d "$d/gen" ] || continue
	# a cross example's gen/ is transpiled freestanding; check_no_heap.sh gates its image
	grep -rq arm-none-eabi "$d" --include='Makefile*' && continue
	n_checked=$((n_checked + 1))
	if ! out=$("$v" -gc none -warn-about-allocs -path "@vlib|@vmodules|.|examples/$n" -o "$tmp/$n.c" "examples/$n" 2>&1); then
		echo "check_host_allocs: examples/$n does not compile:" >&2
		printf '%s\n' "$out" | tail -5 >&2
		fail=1
		continue
	fi
	hits=$(printf '%s\n' "$out" | grep -E "^examples/$n/gen/[^:]+:[0-9]+:[0-9]+: warning: allocation" || true)
	if [ -n "$hits" ]; then
		echo "check_host_allocs: examples/$n allocates in its generated code:" >&2
		printf '%s\n' "$hits" | sed 's/^/  /' >&2
		fail=1
	fi
done
[ "$n_checked" -gt 0 ] || { echo "check_host_allocs: no host example found" >&2; exit 2; }
[ $fail = 0 ] && echo "check_host_allocs: ok ($n_checked host examples)"
exit $fail
