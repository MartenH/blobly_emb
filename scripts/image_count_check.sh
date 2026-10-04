#!/usr/bin/env bash
# image_count_check.sh — the cross job's inventory, as the guide and the workflow state it, is what
# the cross loop actually builds: the directories it visits (a Makefile with arm-none-eabi in or
# under it), the applications among them (a V transpile rule, $(BUILD)/<x>.c), and the bootloaders
# (a node declaring [boot]). A node gaining [boot] or an example added or retired changes them, and
# the stated numbers went stale that way once already (#374). Exits 1 naming the mismatch.
set -uo pipefail
cd "$(dirname "$0")/.."
dirs=0
apps=0
for d in examples/*/ examples/*/nodes/*/; do
	[ -f "$d/Makefile" ] || continue
	grep -rq arm-none-eabi "$d" --include='Makefile*' || continue
	dirs=$((dirs + 1))
	grep -qE '^\$\(BUILD\)/[a-z_]+\.c:' "$d/Makefile" && apps=$((apps + 1))
done
boots=$(grep -lx '\[boot\]' examples/*/ecu.toml examples/*/nodes/*/ecu.toml | wc -l)
images=$((apps + boots))
want="$images STM32H7 images, $apps applications and $boots bootloaders (the cross loop visits $dirs directories"
fail=0
for f in CLAUDE.md .github/workflows/ci.yml; do
	n=$(grep -cF "$want" "$f")
	if [ "$n" = 0 ]; then
		echo "image_count_check: $f does not say \"$want\""
		fail=1
	fi
done
# ...and no other count statement may contradict it: every "<N> cross/STM32H7 images" and
# "every image — <N> of them", line breaks folded, must name the same number
for f in CLAUDE.md .github/workflows/ci.yml; do
	stale=$(tr '\n' ' ' <"$f" | sed 's/#//g' | tr -s ' ' |
		grep -oE '\b[0-9]+ (cross|STM32H7) images|every image — [0-9]+ of them' |
		sed -E 's/^([0-9]+) .*/\1/; s/^every image — ([0-9]+) of them$/\1/' | grep -vx "$images" | sort -u | tr '\n' ' ')
	if [ -n "$stale" ]; then
		echo "image_count_check: $f still states a different image count: $stale(want $images)"
		fail=1
	fi
done
[ $fail = 0 ] && echo "image_count_check: $images images ($apps applications, $boots bootloaders), $dirs directories"
exit $fail
