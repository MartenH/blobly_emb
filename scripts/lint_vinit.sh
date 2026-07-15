#!/bin/bash
# lint_vinit.sh <generated.c> — the _vinit gate for freestanding images.
#
# V compiles a __global's struct-field DEFAULTS into _vinit(), which a
# -freestanding image NEVER CALLS: every such default silently reads 0 on
# target while host builds see the real value. Four bench casualties so far
# (a $d const, Prog.seed, Link.n_bs_us, Journal.pending_erase). This gate
# fails the build if any `// global` initializer inside _vinit carries a
# non-zero scalar or a string — the fix is always the same: drop the field
# default and set the value in an explicit init path both worlds run.
#
# Known limit: enum identifiers are not resolved (a non-zero enum default
# would pass); numeric and string defaults — the observed class — are caught.
set -u
f="$1"
[ -r "$f" ] || { echo "lint_vinit: cannot read $f" >&2; exit 2; }
body=$(awk '/^void _vinit\(int ___argc, voidptr ___argv\) \{/{on=1} on{print} on&&/^\}/{exit}' "$f")
bad=$(printf '%s\n' "$body" | grep '// global' | grep -E '=[[:space:]]*-[0-9]|\.([A-Za-z_0-9]+)[[:space:]]*=[[:space:]]*(-[0-9]+|0x0*[1-9a-fA-F][0-9a-fA-F]*|[1-9][0-9]*)\b|_S\(' || true)
if [ -n "$bad" ]; then
    echo "lint_vinit: $f: __global initializers live in _vinit, which freestanding NEVER runs —" >&2
    echo "these non-zero field defaults read 0 on target (drop the default; set it in an init fn):" >&2
    printf '%s\n' "$bad" | sed -E 's/ *= \*\([A-Za-z_0-9]+\*\)&.*\{\{/ = {/; s/\[0\]\); \/\/ global [0-9]+//' \
        | grep -oE '^\s*[A-Za-z_0-9]+|\.[A-Za-z_0-9]+ = (-[0-9]+|0x0*[1-9a-fA-F][0-9a-fA-F]*|[1-9][0-9]*)|_S\([^)]*\)' \
        | paste -sd' ' - | fold -s -w 100 >&2
    exit 1
fi
exit 0
