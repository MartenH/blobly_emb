#!/bin/sh
# vdeps.sh TARGET SOURCES [DIRS] — the make dependencies of TARGET on what it was built from, on
# stdout: SOURCES lists the files (V's -dump-files: the program's own and every module it imports,
# vlib included; plus any C sources), DIRS any further directories (a `#flag -I` one). Each source's
# directory and each further one is watched for .v, .c and .h — every file found there NOW is named,
# so an edit or a deletion remakes TARGET, and a wildcard per directory, so a NEW file does too.
# A source that disappears must remake TARGET, not stop make (gcc -MP): each gets an empty rule.
#
# A relative path in either list is taken against $VDEPS_BASE when it is set (V reports paths
# relative to where it ran — a Makefile that runs V after `cd $(REPO)` passes the repo root).
#
# The ONE writer of these lists: scripts/build_tool.sh (tools/tools.mk's tool binaries), every
# target image's generated C (its Makefile's app.c rule) and the bootloader's (boot/boot.mk). So no
# Makefile names a module directory by hand — a module the program starts importing is a
# dependency the moment it is compiled in (scripts/app_deps_check.sh pins it).
set -eu
target=$1
sources=$2
extra=${3:-}

abs() {
	case $1 in
		/*) printf '%s\n' "$1" ;;
		*) if [ -n "${VDEPS_BASE:-}" ]; then printf '%s/%s\n' "$VDEPS_BASE" "${1#./}"; else printf '%s\n' "$1"; fi ;;
	esac
}

srcs=$(while read -r f; do [ -n "$f" ] && abs "$f"; done <"$sources" | sort -u)
dirs=$({
	printf '%s\n' "$srcs" | sed 's|/[^/]*$||'
	if [ -n "$extra" ]; then while read -r d; do [ -n "$d" ] && abs "$d"; done <"$extra"; fi
} | awk 'NF && !seen[$0]++')
all=$({
	printf '%s\n' "$srcs"
	printf '%s\n' "$dirs" | while read -r d; do
		for f in "$d"/*.v "$d"/*.c "$d"/*.h; do [ -f "$f" ] && printf '%s\n' "$f"; done
	done
} | awk 'NF' | sort -u)

printf '%s:' "$target"
printf '%s\n' "$all" | while read -r f; do printf ' \\\n  %s' "$f"; done
printf '\n'
printf '%s\n' "$dirs" | while read -r d; do printf '%s: $(wildcard %s/*.v %s/*.c %s/*.h)\n' "$target" "$d" "$d" "$d"; done
printf '%s\n' "$all" | while read -r f; do printf '%s:\n' "$f"; done
