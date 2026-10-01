#!/usr/bin/env bash
# check_implicit_wide.sh <build-log> <example-dir> — fail when gcc implicitly declared a C function
# that the example's V code declares with a return wider or other than int (u64/i64/f32/f64).
# Without a prototype gcc assumes `int`, so such a result is cut to 32 bits (and, for an
# integer, sign-extended): board_now_us() did exactly that, and every target's `now` went
# negative 35.8 minutes after boot. An int- or void-returning implicit call is ABI-safe here.
set -uo pipefail
log="$1"
dir="$2"
bad=0
for fn in $(grep -oE "implicit declaration of function '[A-Za-z0-9_]+'" "$log" | sed -E "s/.*'(.*)'/\1/" | sort -u); do
  if grep -rqE "fn C\.${fn}\([^)]*\) *(u64|i64|f32|f64)\b" "$dir" --include='*.v' 2>/dev/null; then
    echo "check_implicit_wide: ${dir}: ${fn} returns a wide type but has no C prototype — gcc truncates it to int" >&2
    bad=1
  fi
done
exit $bad
