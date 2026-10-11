#!/bin/bash
# check_no_heap_test.sh — pins what scripts/check_no_heap.sh must refuse and must pass, on a
# fake nm (the gate reads nothing but the symbol list), so it needs no ARM toolchain.
set -u
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
touch "$tmp/image.elf"
fail=0
check() { # check <want exit> <label> <symbols the fake nm lists>
	printf '#!/bin/sh\ncat <<"NM_EOF"\n%s\nNM_EOF\n' "$3" > "$tmp/nm"
	chmod +x "$tmp/nm"
	NM="$tmp/nm" "$here/check_no_heap.sh" "$tmp/image.elf" > /dev/null 2>&1
	rc=$?
	if [ "$rc" != "$1" ]; then
		echo "FAIL: $2 (exit $rc, want $1)"
		fail=1
	fi
}
clean='08000000 T blob_entry
08000100 T v_panic
08000140 T bare_panic
08000180 t memcpy'
check 0 'an image whose entry reaches no allocator' "$clean"
check 1 'a local V3 moved to the heap (memdup)' "$clean
08000200 T memdup"
check 1 'a fixed array copied into a dynamic one' "$clean
08000300 T new_array_from_c_array"
check 1 'the C allocator, local symbol' "$clean
08000400 t malloc"
check 1 'newlib heap underneath it' "$clean
08000500 T _sbrk"
check 0 'a name that only contains an allocator name' "$clean
08000600 T my_malloc_pool
08000700 T memdup_count"
printf '#!/bin/sh\nexit 1\n' > "$tmp/nm"
NM="$tmp/nm" "$here/check_no_heap.sh" "$tmp/image.elf" > /dev/null 2>&1
[ $? = 2 ] || { echo "FAIL: an unreadable image is not a clean one (want exit 2)"; fail=1; }
[ $fail = 0 ] && echo "check_no_heap_test: ok"
exit $fail
