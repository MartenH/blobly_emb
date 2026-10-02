#!/bin/sh
# build_tool.sh OUT 'FLAGS' SRC — compile one repo tool to OUT with the compiler in $V (a word
# list: `v -cc clang` works) and record what it was built from: OUT.d, the make dependencies,
# and OUT.sig, the compiler signature $TOOL_SIG that tools/tools.mk compares. Called by
# tools/tools.mk only; the list of inputs and how each reaches make is written there.
#
# Two make processes may build the same OUT at once (two node builds each running the root's
# `make gen-system`), so the tool is compiled under a name of this process's own and renamed
# into place: a rename is atomic, so a reader execs the old tool or the new one, never half of
# either — the shared, self-deleting binary of `v run` is what #313 / #333 were.
#
# OUT.d lists every source V compiled into the tool (`-dump-files`: the tool's own files and
# every module it imports, vlib included) and every C source the C compiler was handed
# (`-dump-c-flags`, the C a module pulls in with `#flag`), plus a wildcard for .v, .c and .h over
# each of their directories and each `#flag -I` directory — so an edit, a deletion or a NEW file
# there rebuilds it. A header reached only through a relative #include outside those directories
# is not seen: that would take the C compiler's own -MD, which V does not expose.
set -eu
out=$1
flags=$2
src=$3

mkdir -p "$(dirname "$out")"
tmp="$out.tmp.$$"
# temporaries must not end in .d or .sig: tools.mk includes bin/.tool-*.d, and a make starting
# while this one writes would read half a makefile
dtmp="$out.d.tmp.$$"
trap 'rm -f "$tmp" "$tmp.files" "$tmp.cflags" "$dtmp"' EXIT
# V and FLAGS are word lists (`v -cc clang`, `-prod -gc none`), so both are split on purpose
# shellcheck disable=SC2086
${V:-v} $flags -dump-files "$tmp.files" -dump-c-flags "$tmp.cflags" -o "$tmp" "$src"

# C inputs: `-I dir` / `-I"dir"` directories, and existing .c/.h/.S sources (not V's own .tmp.c)
cdeps=$(tr -d '"'"'" <"$tmp.cflags" | awk '
	/^-I/ { d = substr($0, 3); sub(/^ +/, "", d); if (d != "") print "I " d; next }
	/\.(c|h|S)$/ && $0 !~ /\.tmp\.c$/ && $0 !~ /^-/ { print "F " $0 }')

{
	cat "$tmp.files"
	printf '%s\n' "$cdeps" | awk '$1 == "F" { print $2 }' | while read -r f; do
		[ -f "$f" ] && printf '%s\n' "$f"
	done
} | sort -u | awk -v out="$out" -v incs="$(printf '%s\n' "$cdeps" | awk '$1 == "I" { print $2 }')" '
	{ f[NR] = $0; d = $0; sub(/\/[^\/]*$/, "", d); if (!(d in seen)) { seen[d] = 1; dirs[++nd] = d } }
	END {
		n = split(incs, inc, "\n")
		for (i = 1; i <= n; i++) if (inc[i] != "" && !(inc[i] in seen)) { seen[inc[i]] = 1; dirs[++nd] = inc[i] }
		printf "%s:", out
		for (i = 1; i <= NR; i++) printf " \\\n  %s", f[i]
		printf "\n"
		for (i = 1; i <= nd; i++) printf "%s: $(wildcard %s/*.v %s/*.c %s/*.h)\n", out, dirs[i], dirs[i], dirs[i]
		# a source that disappears must rebuild the tool, not stop make (gcc -MP)
		for (i = 1; i <= NR; i++) printf "%s:\n", f[i]
	}' >"$dtmp"

# The order makes an interruption safe: the old signature goes first (no record rebuilds the
# tool), then the dependencies, then the binary, and the new signature last — so a signature
# never vouches for a binary it was not built with.
rm -f "$out.sig"
mv -f "$dtmp" "$out.d"
mv -f "$tmp" "$out"
printf '%s\n' "${TOOL_SIG:-}" >"$out.sig.tmp.$$"
mv -f "$out.sig.tmp.$$" "$out.sig"
