#!/usr/bin/env bash
# app_deps_check.sh — the C a target image transpiles from V (its app.c, a bootloader's boot.c) is
# remade when any V source compiled into it changes: the dependency list is V's own -dump-files
# (tools/tools.mk v_deps, scripts/vdeps.sh), never a hand list of module directories — one that
# went stale the day a generated image started importing driver/doipnet. The checks:
#   - every transpile rule is the shape tools/tools.mk documents: its entry point and generation
#     stamp, its record's v_unrecorded, nothing hand-listed — and the Makefile includes tools.mk
#     before it (a macro used before its definition expands to nothing, silently);
#   - per image built, the C has its record; without the record the C is out of date; touching a
#     repo module it compiles in (driver/doipnet where it imports it), or the rule that records
#     it, leaves the C out of date — each asked of make.
# Run after the cross builds (the CI cross job does); exits 1 on a stale dependency.
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
# a transpile rule — the C file V writes — not in the documented shape
if grep -nE '^\$\((BUILD|BOOT_DIR)\)/[a-z_]+\.c:' examples/*/Makefile examples/*/nodes/*/Makefile boot/boot.mk \
	| grep -vE ':\$\(BUILD\)/([a-z_]+)\.c: (\$\(SYSDIR\)/)?main\.v( gen/(\.stamp|loom_gen\.v))? \$\(call v_unrecorded,\$\(BUILD\)/\1\.c\) \| \$\(BUILD\)$' \
	| grep -vE '^boot/boot\.mk:[0-9]+:\$\(BOOT_DIR\)/boot\.c: \$\(call v_unrecorded,\$\(BOOT_DIR\)/boot\.c\) \| \$\(BOOT_DIR\)$'; then
	echo "app_deps_check: a transpile rule (above) is not the tools/tools.mk shape — v_unrecorded, no hand-listed sources"
	fail=1
fi
for mk in examples/*/Makefile examples/*/nodes/*/Makefile; do
	r=$(grep -nE '^\$\(BUILD\)/[a-z_]+\.c:.*v_unrecorded' "$mk" | head -1 | cut -d: -f1)
	[ -n "$r" ] || continue
	i=$(grep -nF 'include $(REPO)/tools/tools.mk' "$mk" | head -1 | cut -d: -f1)
	if [ -z "$i" ] || [ "$i" -gt "$r" ]; then
		echo "app_deps_check: $mk uses tools/tools.mk's macros without including it first"
		fail=1
	fi
done
for mk in examples/*/Makefile examples/*/nodes/*/Makefile; do
	grep -q 'v_deps' "$mk" || continue
	d=$(dirname "$mk")
	for c in "$d"/build/app.c "$d"/build/canfd.c "$d"/build/boot/boot.c; do
		[ -f "$c" ] || continue
		rel=${c#"$d"/}
		make -C "$d" "$rel" >/dev/null 2>&1 || { echo "app_deps_check: $c does not build"; fail=1; continue; }
		[ -f "$c.d" ] || { echo "app_deps_check: $c built without its record ($c.d)"; fail=1; continue; }
		make -C "$d" -q "$rel" >/dev/null 2>&1 || { echo "app_deps_check: $c out of date after a build"; fail=1; continue; }
		# without its record the C is not current, whatever its age
		rm -f "$c.d"
		if make -C "$d" -q "$rel" >/dev/null 2>&1; then
			echo "app_deps_check: $c without its record reads as up to date"
			fail=1
		fi
		make -C "$d" "$rel" >/dev/null 2>&1 && [ -f "$c.d" ] || { echo "app_deps_check: $c did not rebuild its record"; fail=1; continue; }
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
