#!/usr/bin/env bash
# app_deps_check.sh — the C a target image transpiles from V (its app.c, a bootloader's boot.c) is
# remade when any V source compiled into it changes: the dependency list is V's own -dump-files
# (tools/tools.mk v_deps, scripts/vdeps.sh), never a hand list of module directories — one that
# went stale the day a generated image started importing driver/doipnet. Two checks:
#   - no Makefile names a module directory as a transpile prerequisite;
#   - per built image, touching a repo module it compiles in (driver/doipnet where it imports it)
#     leaves its C out of date, asked of make.
# Run after the cross builds (the CI cross job does); exits 1 on a stale dependency.
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
# a transpile rule — the C file V writes — whose prerequisites name sources by hand
if grep -nE '^\$\((BUILD|BOOT_DIR)\)/[a-z_]+\.c:.*(\$\(wildcard|\.v)' examples/*/Makefile examples/*/nodes/*/Makefile boot/boot.mk \
	| grep -vE ':\$\(BUILD\)/[a-z_]+\.c: (\$\(SYSDIR\)/)?main\.v( gen/(\.stamp|loom_gen\.v))? \| \$\(BUILD\)$'; then
	echo "app_deps_check: a transpile rule hand-lists V sources (above) — use tools/tools.mk v_deps"
	fail=1
fi
for mk in examples/*/Makefile examples/*/nodes/*/Makefile; do
	grep -q 'v_deps' "$mk" || continue
	d=$(dirname "$mk")
	for c in "$d"/build/app.c "$d"/build/canfd.c "$d"/build/boot/boot.c; do
		[ -f "$c.files" ] || continue
		rel=${c#"$d"/}
		make -C "$d" "$rel" >/dev/null 2>&1 || { echo "app_deps_check: $c does not build"; fail=1; continue; }
		make -C "$d" -q "$rel" >/dev/null 2>&1 || { echo "app_deps_check: $c out of date after a build"; fail=1; continue; }
		# a repo module it compiles in: the shared DoIP loop where it imports it, else the first one
		src=$(grep -m1 'driver/doipnet/doipnet.v' "$c.files" || grep -m1 -E '^\./(comm|loom|driver|boot|bcrypto|nvm)/' "$c.files")
		[ -n "$src" ] || { echo "app_deps_check: $c compiles in no repo module?"; fail=1; continue; }
		touch "${src#./}"
		if make -C "$d" -q "$rel" >/dev/null 2>&1; then
			echo "app_deps_check: touching ${src#./} leaves $c up to date — a dependency is missing"
			fail=1
		fi
		make -C "$d" "$rel" >/dev/null 2>&1 || { echo "app_deps_check: $c rebuild failed"; fail=1; }
		# and the rule that records the dependencies
		for rule in scripts/vdeps.sh tools/tools.mk; do
			touch "$rule"
			if make -C "$d" -q "$rel" >/dev/null 2>&1; then
				echo "app_deps_check: touching $rule leaves $c up to date"
				fail=1
			fi
			make -C "$d" "$rel" >/dev/null 2>&1 || { echo "app_deps_check: $c rebuild failed"; fail=1; }
		done
		echo "app_deps_check: $c ok (${src#./}, the rule)"
	done
done
exit $fail
