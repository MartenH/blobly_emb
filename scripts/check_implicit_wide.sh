#!/usr/bin/env bash
# check_implicit_wide.sh <build-log> — fail when gcc implicitly declared a C function that any V
# code in this repo declares with a return other than int (u64/i64/f32/f64). Without a prototype
# gcc assumes `int`, so such a result is cut to 32 bits (and, for an integer, sign-extended):
# board_now_us() did exactly that, and every target's `now` went negative 35.8 minutes after
# boot. An int- or void-returning implicit call is ABI-safe on this target. boards/*/board.mk
# force-includes board.h, which is the fix; this is the guard for the next such function.
#
# Limits, stated: an image compiled with -w prints no warning to find (board.mk's -include still
# covers board.h there); a struct or alias return is not matched. Run the build under LC_ALL=C so
# gcc quotes names with ASCII quotes (the match takes the typographic ones too).
set -uo pipefail
log="${1:?usage: check_implicit_wide.sh <build-log>}"
[ -r "$log" ] || { echo "check_implicit_wide: cannot read $log" >&2; exit 2; }
root="$(cd "$(dirname "$0")/.." && pwd)"
bad=0
for fn in $(grep -oE "implicit declaration of function ['‘][A-Za-z0-9_]+['’]" "$log" |
	sed -E "s/.*['‘]([A-Za-z0-9_]+)['’]/\1/" | sort -u); do
	if grep -rqE "fn C\.${fn}\([^)]*\) *(u64|i64|f32|f64)\b" "$root" --include='*.v' \
		--exclude-dir=third_party --exclude-dir=.claude 2>/dev/null; then
		echo "check_implicit_wide: ${fn} returns a wide type but has no C prototype — gcc truncates it to int" >&2
		bad=1
	fi
done
exit $bad
