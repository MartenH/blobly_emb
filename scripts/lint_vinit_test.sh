#!/bin/bash
# lint_vinit_test.sh — pins the shapes scripts/lint_vinit.sh must refuse and must pass, on
# synthetic _vinit bodies in the generated-C form (one `// global` initializer per line).
set -u
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { # check <want: refuse|pass> <label> <initializer line>
	printf 'void _vinit(int ___argc, voidptr ___argv) {\n%s\n}\n' "$3" >"$tmp/g.c"
	"$here/lint_vinit.sh" "$tmp/g.c" >/dev/null 2>&1
	rc=$?
	if { [ "$1" = refuse ] && [ $rc -ne 1 ]; } || { [ "$1" = pass ] && [ $rc -ne 0 ]; }; then
		echo "FAIL: $2 (want $1, exit $rc)"
		fail=1
	fi
}
check refuse 'a non-zero field default' '	g_x = *(T*)&((T[]){{.n = 4,}}[0]); // global 5'
check refuse 'a hex field default' '	g_x = *(T*)&((T[]){{.mask = 0x10,}}[0]); // global 5'
check refuse 'a negative default' '	g_x = *(T*)&((T[]){{.n = -1,}}[0]); // global 5'
check refuse 'a bool field defaulting to true' '	g_x = *(T*)&((T[]){{.on = 0,.handoff_here = true,}}[0]); // global 5'
check refuse 'a string default' '	g_x = *(T*)&((T[]){{.s = _SLIT("x"),}}[0]); // global 5'
check refuse 'a bare scalar global' '	g_n = 42; // global 5'
check pass 'zero and false defaults' '	g_x = *(T*)&((T[]){{.n = 0,.on = false,.f = 0,}}[0]); // global 5'
check pass 'a field whose name contains true' '	g_x = *(T*)&((T[]){{.untrue = 0,}}[0]); // global 5'
[ $fail = 0 ] && echo "lint_vinit_test: ok"
exit $fail
