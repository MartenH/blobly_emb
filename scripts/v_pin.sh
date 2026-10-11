#!/usr/bin/env sh
# Report the V compiler CI pins (.v-version) against the one this build would use.
#
# They do NOT have to match — working against another V is sometimes deliberate. This exists so
# that when a build passes locally and fails in CI (or the reverse), the compiler is the FIRST thing
# ruled in or out instead of the last. Advisory only; it never fails a build.
#
# $1 (optional) is the compiler to inspect — `make v-pin` passes $(V), so a `V=/path/to/v` build
# is compared against the compiler it actually uses rather than whatever `v` PATH resolves to.
set -eu
root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
pin="$(tr -d '[:space:]' < "$root/.v-version")"
vc_pin="$(tr -d '[:space:]' < "$root/.vc-version")"
vbin="${1:-v}"
raw="$("$vbin" version 2>/dev/null || true)"

printf 'CI pin      : V %s + vc %s (built from source, .github/actions/setup-v)\n' "$pin" "$vc_pin"
if [ -z "$raw" ]; then
	printf 'your V      : %s — not found\n' "$vbin"
	printf 'status      : UNKNOWN\n'
	exit 0
fi
printf 'your V      : %s (%s)\n' "$raw" "$vbin"

# `v version` prints "V <release> <revision>", e.g. "V 0.5.2 e7bb21c". The pin is a COMMIT, so
# the revision is what is compared — a release number is kept by every build after the release.
rev="$(printf '%s\n' "$raw" | awk '{print $3}')"
case "$pin" in
"$rev"*)
	if [ -n "$rev" ]; then
		printf 'status      : same commit (%s)\n' "$rev"
		exit 0
	fi
	;;
esac
printf 'status      : DIFFERENT (%s vs pinned %.7s) — fine, but suspect the compiler first if CI and local disagree; scripts/v_toolchain.sh builds the pin\n' "${rev:-?}" "$pin"
