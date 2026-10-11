#!/usr/bin/env bash
# check_no_heap.sh <image.elf> — the no-heap gate for a bare-metal image (docs/no-alloc.md).
#
# Images link with --gc-sections, which keeps only what the entry reaches: an allocator still in
# the image is an allocation the target can reach. V3 makes those out of code that never looks
# like one — a local whose address reaches a call it cannot see through is moved to the heap, a
# fixed array is copied into a dynamic one to call `.any()` — and on target every one of them is
# nil from osal/vrt and a halt. Nothing else says so before the bench does.
#
#   NM=<nm>   the symbol lister (default arm-none-eabi-nm); scripts/check_no_heap_test.sh fakes it
set -euo pipefail
elf=${1:?usage: check_no_heap.sh <image.elf>}
nm=${NM:-arm-none-eabi-nm}
syms=$("$nm" "$elf") || { echo "check_no_heap: $nm could not read $elf" >&2; exit 2; }
# V's allocation entry points, the libc allocator and newlib's heap underneath it
found=$(printf '%s\n' "$syms" | awk 'NF >= 3 {print $3}' | grep -xE \
	'v_malloc|malloc_noscan|malloc_uninit|vcalloc|vcalloc_noscan|v_realloc|realloc_data|memdup|memdup_noscan|memdup_uncollectable|v3_aligned_memdup|__new_array|__new_array_noscan|__new_array_with_default|new_array_from_c_array|alloc_array_data|malloc|calloc|realloc|_malloc_r|_calloc_r|_realloc_r|_sbrk' \
	| sort -u || true)
if [ -n "$found" ]; then
	echo "check_no_heap: $elf can reach an allocator (docs/no-alloc.md):" >&2
	printf '  %s\n' $found >&2
	echo "  build it with -warn-about-allocs to see the V locals moved to the heap" >&2
	exit 1
fi
