#!/bin/sh
# build_tool.sh OUT 'FLAGS' SRC — compile one repo tool to OUT with the compiler in $V (a word
# list: `v -cc clang` works) and write OUT.d, the make dependencies that say when it must be
# compiled again. Called by tools/tools.mk only.
#
# Two make processes may build the same OUT at once (two node builds each running the root's
# `make gen-system`), so the tool is compiled under a name of this process's own and renamed
# into place: a rename is atomic, so a reader execs the old tool or the new one, never half of
# either — the shared, self-deleting binary of `v run` is what #313 / #333 were.
#
# OUT.d lists every source V compiled into the tool (`-dump-files`: the tool's own files and
# every module it imports, vlib included), plus a wildcard over each of their directories for
# .v, .c and .h — so an edit, a deletion or a NEW file in an imported module, and the C a module
# pulls in with `#flag` beside its V (osal/osal_native.c), all rebuild it.
set -eu
out=$1
flags=$2
src=$3

mkdir -p "$(dirname "$out")"
tmp="$out.tmp.$$"
# the dependency list's temporary must not end in .d: tools.mk includes bin/.tool-*.d, and a
# make starting while this one writes would read half a makefile
dtmp="$out.d.tmp.$$"
trap 'rm -f "$tmp" "$tmp.files" "$dtmp"' EXIT
# V and FLAGS are word lists (`v -cc clang`, `-prod -gc none`), so both are split on purpose
# shellcheck disable=SC2086
${V:-v} $flags -dump-files "$tmp.files" -o "$tmp" "$src"

sort -u "$tmp.files" | awk -v out="$out" '
	{ f[NR] = $0; d = $0; sub(/\/[^\/]*$/, "", d); if (!(d in seen)) { seen[d] = 1; dirs[++nd] = d } }
	END {
		printf "%s:", out
		for (i = 1; i <= NR; i++) printf " \\\n  %s", f[i]
		printf "\n"
		for (i = 1; i <= nd; i++) printf "%s: $(wildcard %s/*.v %s/*.c %s/*.h)\n", out, dirs[i], dirs[i], dirs[i]
		# a source that disappears must rebuild the tool, not stop make (gcc -MP)
		for (i = 1; i <= NR; i++) printf "%s:\n", f[i]
	}' >"$dtmp"

# the dependencies first: a crash between the two leaves new deps beside an old tool, which
# rebuilds it, never old deps beside a new one
mv -f "$dtmp" "$out.d"
mv -f "$tmp" "$out"
