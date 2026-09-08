#!/usr/bin/env sh
# Report the V compiler CI pins (.v-version) against the one this build would use.
#
# They do NOT have to match — working against V master is often deliberate. This exists so that
# when a build passes locally and fails in CI (or the reverse), the compiler is the FIRST thing
# ruled in or out instead of the last: CI installs the pinned prebuilt release, your shell does
# not. Advisory only; it never fails a build.
#
# $1 (optional) is the compiler to inspect — `make v-pin` passes $(V), so a `V=/path/to/v` build
# is compared against the compiler it actually uses rather than whatever `v` PATH resolves to.
set -eu
root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
pin="$(tr -d '[:space:]' < "$root/.v-version")"
vbin="${1:-v}"
raw="$("$vbin" version 2>/dev/null || true)"

printf 'CI pin      : %s (prebuilt v_linux.zip release asset)\n' "$pin"
if [ -z "$raw" ]; then
	printf 'your V      : %s — not found\n' "$vbin"
	printf 'status      : UNKNOWN\n'
	exit 0
fi
printf 'your V      : %s (%s)\n' "$raw" "$vbin"

# `v version` prints "V <release> <revision>", e.g. "V 0.5.1 88dc895". Compare the RELEASE token
# exactly: a substring test would call pin 0.5.2 a match for 0.5.20, and it would also hide the
# common case where a development build keeps the last release's number but is many commits past
# it — which is exactly the difference this is meant to surface.
rel="$(printf '%s\n' "$raw" | awk '{print $2}')"
rev="$(printf '%s\n' "$raw" | awk '{print $3}')"
if [ "$rel" != "$pin" ]; then
	printf 'status      : DIFFERENT (%s vs pinned %s) — fine, but suspect the compiler first if CI and local disagree\n' "$rel" "$pin"
elif [ -n "$rev" ]; then
	# The release token matching is NOT proof of the same compiler: a development build many
	# commits past a release still reports that release's number (this repo's own working V
	# reported 0.5.1 while its source sat 400+ commits past 0.5.2). Report the revision and say
	# what it does and does not establish, rather than claiming a match we cannot verify offline.
	printf 'status      : release matches (%s) at revision %s — note a dev build past the release keeps the release number\n' "$rel" "$rev"
else
	printf 'status      : release matches (%s)\n' "$rel"
fi
