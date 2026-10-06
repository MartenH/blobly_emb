#!/usr/bin/env bash
# app_deps_check.sh — an image is remade when anything it was built from changes, whichever
# compiler read it:
#   - V: the C a target image transpiles (its app.c, a bootloader's boot.c) depends on every V
#     source compiled into it — V's own -dump-files (tools/tools.mk v_deps, scripts/vdeps.sh), never
#     a hand list of module directories, one that went stale the day a generated image started
#     importing driver/doipnet;
#   - C: what an image compiles C into (its ELF, an app.o, a bootloader's boot.elf, the objects of
#     its ThreadX/NetX/LVGL archives) depends on every header and textually included file its
#     sources read — the compiler's own -MM -MP (tools/tools.mk c_build, c_object), never a hand
#     list of headers, one that missed bootmap.h's flash addresses (#375) — and on how the compiler
#     is run, every flag and source (tools/tools.mk c_sign, #382).
# The checks:
#   - every transpile rule is the shape tools/tools.mk documents: its entry point and generation
#     stamp, its record's v_unrecorded, nothing hand-listed — and the Makefile includes tools.mk
#     before it (a macro used before its definition expands to nothing, silently);
#   - every rule whose recipe runs $(CC) runs it through c_build (an image's ELF, an app.o, a
#     boot.elf) or c_object (an archive's objects, $(BUILD)/tx/, $(BUILD)/nx/, $(BUILD)/lvgl/),
#     with its c_unrecorded, its c_sign of the very variable the recipe runs, its records included
#     and no header named by hand;
#   - per image built, the target has its record; without the record it is out of date; touching
#     a repo module it compiles in (driver/doipnet where it imports it), a header it includes
#     (the board's bootmap.h where it reads one, and the forced board.h), or the rule that records
#     it, leaves it out of date; so does another flag (MCU, and DEBUG=1 where the Makefile has
#     one), while the unchanged command leaves it up to date — each asked of make, apps and
#     bootloaders alike, and of one object of each archive.
# Run after the cross builds (the CI cross job does); exits 1 on a stale dependency.
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
tmpf=$(mktemp) || exit 1
# A what-if with another flag rewrites the signatures make reads (tools/tools.mk c_sign writes one
# whenever it differs), and writing the old text back would make it NEWER than what it signs: keep
# them, with their times, and put them back after asking — on any exit too, so an interrupted run
# leaves no signature of a command nobody built.
kept=
sigs_keep() {
	kept=$1
	find "$1/build" -name '*.sig' -exec cp -p {} {}.keep \;
}
sigs_back() {
	[ -n "$kept" ] || return 0
	# a signature the what-if created has nothing to go back to
	find "$kept/build" -name '*.sig' | while read -r f; do [ -f "$f.keep" ] || rm -f "$f"; done
	find "$kept/build" -name '*.sig.keep' | while read -r k; do mv -f "$k" "${k%.keep}"; done
	kept=
}
trap 'sigs_back; rm -f "$tmpf"' EXIT
# make's answer for <dir> <target> with the extra make arguments: stale, current, or (reported) none
ask() {
	local d=$1 t=$2; shift 2
	make -C "$d" -q "$@" "$t" >/dev/null 2>&1
	case $? in
		1) echo stale ;;
		0) echo current ;;
		*) echo none; echo "app_deps_check: make could not answer for $d/$t ($*)" >&2 ;;
	esac
}
# out of date / up to date, each false when make could not answer (ask reports that, and fails)
stale() { local a; a=$(ask "$@"); [ "$a" = none ] && fail=1; [ "$a" = stale ]; }
current() { local a; a=$(ask "$@"); [ "$a" = none ] && fail=1; [ "$a" = current ]; }
# another flag leaves <dir> <target> out of date: MCU (MCU_CM4 on a CM4 image; on every compile
# line), DEBUG=1 where the Makefile reads one; the signatures are restored after, and the target
# is current again. Asked of a target just built, before any -W what-if: one of tools.mk remakes
# the generators, and with them the generated headers the target reads.
flags_check() {
	local d=$1 t=$2; shift 2
	sigs_keep "$d"
	stale "$d" "$t" "$@" MCU=-DAPP_DEPS_CHECK MCU_CM4=-DAPP_DEPS_CHECK || { echo "app_deps_check: $d/$t ignores a change of compile flags (MCU), or make could not say"; fail=1; }
	if grep -qF 'ifeq ($(DEBUG),1)' "$d/Makefile"; then
		stale "$d" "$t" "$@" DEBUG=1 || { echo "app_deps_check: $d/$t ignores DEBUG=1, or make could not say"; fail=1; }
	fi
	sigs_back
	current "$d" "$t" "$@" || { echo "app_deps_check: $d/$t is not up to date with its signatures restored"; fail=1; }
}
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
	# A recipe that runs $(CC) runs it as $(call c_build,$(<VAR>)) — an image's ELF, an app.o, a
	# boot.elf, or any other target — or, for the objects of a pinned archive ($(BUILD)/tx/,
	# $(BUILD)/nx/, $(BUILD)/lvgl/ — the kernel, the network stack, the graphics library), as
	# $(call c_object,$(<VAR>)). Either way the rule signs that same variable
	# ($$(call c_sign,$$@,$$(<VAR>)), or the archive's $$(call c_sign,$(<ARCH>_A),$$(<VAR>))),
	# carries its c_unrecorded, includes its records, and names no header: the record carries
	# those. A rule with no recipe only adds a prerequisite to one defined elsewhere (boot/boot.mk
	# relinks the application when the layout its LINK flags are read from changes) and is not a
	# compile.
	awk -v mk="$mk" '
		function done_rule() {
			if (tgt == "" || !cc) return
			if (bare) { print mk ":" start ": " tgt " runs the C compiler without tools/tools.mk c_build or c_object — its headers and flags go untracked"; return }
			p = substr(rule, index(rule, ":") + 1)
			if (p ~ /\.h([[:space:]]|\)|$)/) print mk ":" start ": " tgt " names a header by hand — the record carries it"
			# an order-only signature is never compared: it sits before the |
			if (index(p, " | ") && index(p, "c_sign,") > index(p, " | ")) print mk ":" start ": " tgt "'"'"'s c_sign is order-only (after the |) — a changed command would not remake it"
			if (match(tgt, /^\$\(BUILD\)\/(tx|nx|lvgl)\/%\.o$/)) {
				arch = toupper(substr(tgt, 10, index(substr(tgt, 10), "/") - 1))
				if (how != "c_object") { print mk ":" start ": " tgt " is an archive object built without c_object"; return }
				if (index(rule, "$$(call c_unrecorded,$$@)") == 0) print mk ":" start ": " tgt " has no $$(call c_unrecorded,$$@)"
				if (index(rule, "$$(call c_sign,$(" arch "_A),$$(" var "))") == 0) print mk ":" start ": " tgt " does not sign the command it runs: $$(call c_sign,$(" arch "_A),$$(" var "))"
				recs[mk SUBSEP arch] = 1
				return
			}
			if (how != "c_build") { print mk ":" start ": " tgt " runs c_object, which compiles one archive object — an image is c_build"; return }
			if (index(rule, "$(call c_unrecorded," tgt ")") == 0) print mk ":" start ": " tgt " has no $(call c_unrecorded," tgt ")"
			if (index(rule, "$$(call c_sign,$$@,$$(" var "))") == 0) print mk ":" start ": " tgt " does not sign the command it runs: $$(call c_sign,$$@,$$(" var "))"
			need[mk SUBSEP tgt] = 1
		}
		{ if (cont) { line = line " " $0 } else { line = $0; start_l = NR } }
		{ cont = sub(/\\$/, "", line); if (cont) next }
		# every compiler call in a recipe goes through c_build or c_object, after the recipe
		# prefixes (@ + -), and runs one variable — the one its rule signs
		substr(line, 1, 1) == "\t" {
			if (line ~ /\$\(CC\)/) { cc = 1; bare = 1 }
			if (match(line, /^\t[@+-]*\$\(call c_(build|object),\$\([A-Za-z_][A-Za-z0-9_]*\)\)$/)) {
				cc = 1; how = (index(line, "c_build") ? "c_build" : "c_object")
				var = line; sub(/^.*,\$\(/, "", var); sub(/\)\)$/, "", var)
			} else if (line ~ /c_(build|object)/) { cc = 1; bare = 1 }
			next
		}
		# blank and comment lines may sit among the recipe lines of a rule
		line ~ /^[[:space:]]*(#.*)?$/ { next }
		{ done_rule(); tgt = ""; cc = 0; bare = 0; how = ""; var = "" }
		line ~ /^-include / { f = substr(line, 10); sub(/\.d$/, "", f); inc[mk SUBSEP f] = 1 }
		line ~ /^-include \$\(call c_records,\$\([A-Z]+_OBJ\)\)$/ { an = line; sub(/^.*\$\(call c_records,\$\(/, "", an); sub(/_OBJ\)\)$/, "", an); recinc[mk SUBSEP an] = 1 }
		line ~ /^[^#=:[:space:]][^=:]*:([^=]|$)/ {
			tgt = line; sub(/:.*/, "", tgt); rule = line; start = start_l
			# a recipe on the rule line itself, after a semicolon
			if (index(rule, ";") && substr(rule, index(rule, ";")) ~ /\$\(CC\)/) { cc = 1; bare = 1 }
		}
		END {
			done_rule()
			for (k in need) { split(k, a, SUBSEP); if (!(k in inc)) print mk ": " a[2] "'"'"'s record (" a[2] ".d) is never included" }
			for (k in recs) { split(k, a, SUBSEP); if (!(k in recinc)) print mk ": the " tolower(a[2]) " objects'"'"' records are never included: -include $(call c_records,$(" a[2] "_OBJ))" }
		}' "$mk"
	r=$(grep -nE '^[^#]*c_unrecorded' "$mk" | head -1 | cut -d: -f1)
	[ -n "$r" ] || continue
	i=$(grep -nE '^include \$\(REPO\)/tools/tools.mk' "$mk" | head -1 | cut -d: -f1)
	# boot/boot.mk and a board's display.mk are included by a Makefile that included tools.mk
	if [ "$mk" != boot/boot.mk ] && [[ $mk != boards/*/display.mk ]] && { [ -z "$i" ] || [ "$i" -gt "$r" ]; }; then
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
	# One object of each archive the image links (tools/tools.mk c_object), before the targets
	# below rebuild the archive it lands in: recorded, current, stale without its record, and
	# stale on an edit to the forced board.h or on another flag.
	for a in tx nx lvgl; do
		[ -d "$d/build/$a" ] || continue
		o=$(cd "$d" && find "build/$a" -name '*.o' | sort | head -1)
		[ -n "$o" ] || continue
		make -C "$d" "$o" >/dev/null 2>&1 || { echo "app_deps_check: $d/$o does not build"; fail=1; continue; }
		[ -f "$d/$o.d" ] || { echo "app_deps_check: $d/$o built without its record"; fail=1; continue; }
		current "$d" "$o" || { echo "app_deps_check: $d/$o out of date after a build"; fail=1; continue; }
		rm -f "$d/$o.d"
		stale "$d" "$o" || { echo "app_deps_check: $d/$o without its record reads as up to date"; fail=1; }
		make -C "$d" "$o" >/dev/null 2>&1 && [ -f "$d/$o.d" ] || { echo "app_deps_check: $d/$o did not rebuild its record"; fail=1; continue; }
		bh=$(grep -m1 -E '(^|/)board\.h:$' "$d/$o.d" | sed 's/:$//')
		[ -n "$bh" ] || { echo "app_deps_check: $d/$o's record does not name the forced board.h"; fail=1; continue; }
		flags_check "$d" "$o"
		stale "$d" "$o" -W "$bh" || { echo "app_deps_check: an edit to $bh leaves $d/$o up to date"; fail=1; }
		echo "app_deps_check: $d/$o ok (board.h, the flags)"
	done
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
		# how the compiler is run (tools/tools.mk c_sign): another flag leaves it stale, the
		# same command current — with what it links held old, so only its OWN signature answers
		held=("${old[@]}")
		for a in build/tx.a build/nx.a build/lvgl.a; do
			[ -f "$d/$a" ] && held+=(-o "$a")
		done
		flags_check "$d" "$rel" "${held[@]}"
		for h in $bm $bh $rule; do
			make -C "$d" -q "${old[@]}" -W "$h" "$rel" >/dev/null 2>&1
			case $? in
				1) ;;
				0) echo "app_deps_check: an edit to $h leaves $t up to date — a dependency is missing"; fail=1 ;;
				*) echo "app_deps_check: make could not answer for $t with $h edited"; fail=1 ;;
			esac
		done
		echo "app_deps_check: $t ok (${bm:+$(basename "$bm"), }$(basename "$bh"), the rule, the flags)"
	done
done
exit $fail
