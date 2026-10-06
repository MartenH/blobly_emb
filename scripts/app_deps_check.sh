#!/usr/bin/env bash
# app_deps_check.sh — an image is remade when anything it was built from changes, whichever
# compiler read it:
#   - V: the C a target image transpiles (its app.c, a bootloader's boot.c) depends on every V
#     source compiled into it — V's own -dump-files (tools/tools.mk v_deps, scripts/vdeps.sh), never
#     a hand list of module directories, one that went stale the day a generated image started
#     importing driver/doipnet;
#   - C: what an image compiles C into (its ELF, an app.o, a bootloader's boot.elf) depends on
#     every header and textually included file its sources read — the compiler's own -MM -MP
#     (tools/tools.mk c_build), never a hand list of headers, one that missed bootmap.h's flash
#     addresses (#375).
# The checks:
#   - every transpile rule is the shape tools/tools.mk documents: its entry point and generation
#     stamp, its record's v_unrecorded, nothing hand-listed — and the Makefile includes tools.mk
#     before it (a macro used before its definition expands to nothing, silently);
#   - every rule whose recipe runs $(CC) runs it through c_build, with its c_unrecorded, its record
#     included and no header named by hand — the ThreadX/NetX/LVGL archive objects ($(BUILD)/tx/,
#     $(BUILD)/nx/, $(BUILD)/lvgl/) aside: pinned third-party sources, tracked by Makefile only (#382);
#   - per image built, the target has its record; without the record it is out of date; touching
#     a repo module it compiles in (driver/doipnet where it imports it), a header it includes
#     (the board's bootmap.h where it reads one, and the forced board.h), or the rule that records
#     it, leaves it out of date — each asked of make, apps and bootloaders alike.
# Run after the cross builds (the CI cross job does); exits 1 on a stale dependency.
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
tmpf=$(mktemp) || exit 1
trap 'rm -f "$tmpf"' EXIT
# a transpile rule — the C file V writes — not in the documented shape
if grep -nE '^\$\((BUILD|BOOT_DIR)\)/[a-z_]+\.c:' examples/*/Makefile examples/*/nodes/*/Makefile boot/boot.mk \
	| grep -vE ':\$\(BUILD\)/([a-z_]+)\.c: (\$\(SYSDIR\)/)?main\.v( gen/(\.stamp|loom_gen\.v))? \$\(call v_unrecorded,\$\(BUILD\)/\1\.c\) \$\(call v_sign,\$\(BUILD\)/\1\.c,\$\(TRANSPILE_FLAGS\)\) \| \$\(BUILD\)$' \
	| grep -vE '^boot/boot\.mk:[0-9]+:\$\(BOOT_DIR\)/boot\.c: \$\(call v_unrecorded,\$\(BOOT_DIR\)/boot\.c\) \$\(call v_sign,\$\(BOOT_DIR\)/boot\.c,\$\(BOOT_TRANSPILE_FLAGS\)\) \| \$\(BOOT_DIR\)$'; then
	echo "app_deps_check: a transpile rule (above) is not the tools/tools.mk shape — v_unrecorded, v_sign, no hand-listed sources"
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
	# V runs with the flags the signature records, nothing beside them
	if ! sed -n "$((r + 1))p" "$mk" | grep -qE '^	cd \$\(REPO\) && \$\(V\) \$\(TRANSPILE_FLAGS\) \$\(call v_dump,\$@\) -o '; then
		echo "app_deps_check: $mk: the transpile does not run V with exactly \$(TRANSPILE_FLAGS)"
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
		# how V runs is an input: another define leaves the C out of date
		if make -C "$d" -q "$rel" LOOM_VDEFS="-d app_deps_check" VDBG="-d app_deps_check" BOOT_VDEFS="-d app_deps_check" >/dev/null 2>&1; then
			echo "app_deps_check: $c ignores a change of V flags"
			fail=1
		fi
		make -C "$d" "$rel" >/dev/null 2>&1 || { echo "app_deps_check: $c rebuild failed"; fail=1; }
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

# --- C: what the compiler read -----------------------------------------------------------------
cmks=$(grep -l arm-none-eabi examples/*/Makefile examples/*/nodes/*/Makefile)
for mk in $cmks boot/boot.mk boards/*/display.mk; do
	# Every rule, its logical line (continuations joined), where it starts, and its recipe lines.
	# A recipe that runs $(CC) runs it through c_build — except the pinned third-party kernel,
	# network and graphics archive objects ($(BUILD)/tx/, $(BUILD)/nx/, $(BUILD)/lvgl/). A rule that does (an image's ELF, an
	# app.o, a boot.elf, or any other) carries its c_unrecorded, includes its record, and names no
	# header: the record carries those. A rule with no recipe only adds a prerequisite to one
	# defined elsewhere (boot/boot.mk relinks the application when the layout its LINK flags are
	# read from changes) and is not a compile.
	awk -v mk="$mk" '
		function done_rule() {
			if (tgt == "" || !cc) return
			if (tgt ~ /^\$\(BUILD\)\/(tx|nx|lvgl)\//) return
			if (bare) { print mk ":" start ": " tgt " runs the C compiler without tools/tools.mk c_build — its headers go untracked"; return }
			if (index(rule, "$(call c_unrecorded," tgt ")") == 0) print mk ":" start ": " tgt " has no $(call c_unrecorded," tgt ")"
			need[mk SUBSEP tgt] = 1
			p = substr(rule, index(rule, ":") + 1)
			if (p ~ /\.h([[:space:]]|\)|$)/) print mk ":" start ": " tgt " names a header by hand — the record carries it"
		}
		{ if (cont) { line = line " " $0 } else { line = $0; start_l = NR } }
		{ cont = sub(/\\$/, "", line); if (cont) next }
		# every compiler call in a recipe goes through c_build, after the recipe prefixes (@ + -)
		substr(line, 1, 1) == "\t" {
			if (line ~ /\$\(CC\)/) { cc = 1; if (line !~ /^\t[@+-]*\$\(call c_build,/) bare = 1 }
			next
		}
		# blank and comment lines may sit among the recipe lines of a rule
		line ~ /^[[:space:]]*(#.*)?$/ { next }
		{ done_rule(); tgt = ""; cc = 0; bare = 0 }
		line ~ /^-include / { f = substr(line, 10); sub(/\.d$/, "", f); inc[mk SUBSEP f] = 1 }
		line ~ /^[^#=:[:space:]][^=:]*:([^=]|$)/ {
			tgt = line; sub(/:.*/, "", tgt); rule = line; start = start_l
			# a recipe on the rule line itself, after a semicolon
			if (index(rule, ";") && substr(rule, index(rule, ";")) ~ /\$\(CC\)/) { cc = 1; bare = 1 }
		}
		END {
			done_rule()
			for (k in need) { split(k, a, SUBSEP); if (!(k in inc)) print mk ": " a[2] "'"'"'s record (" a[2] ".d) is never included" }
		}' "$mk"
	r=$(grep -nE '^[^#]*c_unrecorded' "$mk" | head -1 | cut -d: -f1)
	[ -n "$r" ] || continue
	i=$(grep -nE '^include \$\(REPO\)/tools/tools.mk' "$mk" | head -1 | cut -d: -f1)
	if [ "$mk" != boot/boot.mk ] && { [ -z "$i" ] || [ "$i" -gt "$r" ]; }; then
		echo "$mk uses c_unrecorded without including tools/tools.mk first"
	fi
done >"$tmpf"
if [ -s "$tmpf" ]; then
	sed 's/^/app_deps_check: /' "$tmpf"
	fail=1
fi
for mk in $cmks; do
	d=$(dirname "$mk")
	boot=0
	grep -qE '^[[:space:]]*\[boot\][[:space:]]*(#.*)?$' "$d/ecu.toml" 2>/dev/null && boot=1
	for t in "$d"/build/*.elf "$d"/build/app.o "$d"/build/boot/boot.elf; do
		[ -f "$t" ] || continue
		rel=${t#"$d"/}
		make -C "$d" "$rel" >/dev/null 2>&1 || { echo "app_deps_check: $t does not build"; fail=1; continue; }
		[ -f "$t.d" ] || { echo "app_deps_check: $t built without its record ($t.d)"; fail=1; continue; }
		make -C "$d" -q "$rel" >/dev/null 2>&1 || { echo "app_deps_check: $t out of date after a build"; fail=1; continue; }
		# without its record the target is not current, whatever its age
		rm -f "$t.d"
		if make -C "$d" -q "$rel" >/dev/null 2>&1; then
			echo "app_deps_check: $t without its record reads as up to date"
			fail=1
		fi
		make -C "$d" "$rel" >/dev/null 2>&1 && [ -f "$t.d" ] || { echo "app_deps_check: $t did not rebuild its record"; fail=1; continue; }
		# The board's flash map where the image reads it (a [boot] node's app and bootloader must),
		# the board.h forced into every translation unit, and the rule that wrote the record — each
		# asked with make's what-if (-W, nothing touched) and the target's generated C and objects
		# held old (-o), so only the target's OWN record can make it stale. The spelling is the
		# record's: make matches a file by its name.
		bm=$(grep -m1 -E '(^|/)bootmap\.h:$' "$t.d" | sed 's/:$//')
		bh=$(grep -m1 -E '(^|/)board\.h:$' "$t.d" | sed 's/:$//')
		rule=$(grep -m1 -oE '[^ ]*/tools/tools\.mk$' "$t.d")
		if [ -z "$bm" ] && [ "$boot" = 1 ] && [ "$rel" != build/app.o ]; then
			echo "app_deps_check: $t is a [boot] node's image and its record does not name bootmap.h"
			fail=1
		fi
		[ -n "$bh" ] || { echo "app_deps_check: $t's record does not name the forced board.h"; fail=1; continue; }
		[ -n "$rule" ] || { echo "app_deps_check: $t's record does not name tools/tools.mk"; fail=1; continue; }
		old=()
		for o in build/app.o build/app.c build/canfd.c build/boot/boot.c; do
			[ "$o" != "$rel" ] && [ -f "$d/$o" ] && old+=(-o "$o")
		done
		for h in $bm $bh $rule; do
			make -C "$d" -q "${old[@]}" -W "$h" "$rel" >/dev/null 2>&1
			case $? in
				1) ;;
				0) echo "app_deps_check: an edit to $h leaves $t up to date — a dependency is missing"; fail=1 ;;
				*) echo "app_deps_check: make could not answer for $t with $h edited"; fail=1 ;;
			esac
		done
		echo "app_deps_check: $t ok (${bm:+$(basename "$bm"), }$(basename "$bh"), the rule)"
	done
done
exit $fail
