#!/usr/bin/env sh
# Report the V compiler CI pins (.v-version) against the one on your PATH.
#
# They do NOT have to match — working against V master is often deliberate. This exists so that
# when a build passes locally and fails in CI (or the reverse), the compiler is the FIRST thing
# ruled in or out instead of the last: CI installs the pinned prebuilt release, your shell does
# not. Advisory only; it never fails a build.
set -eu
root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
pin="$(tr -d '[:space:]' < "$root/.v-version")"
local_v="$(v version 2>/dev/null || echo 'not found')"
printf 'CI pin      : %s (prebuilt v_linux.zip release asset)\n' "$pin"
printf 'your V      : %s\n' "$local_v"
case "$local_v" in
  *"$pin"*) printf 'status      : match\n' ;;
  *)        printf 'status      : DIFFERENT — fine, but suspect the compiler first if CI and local disagree\n' ;;
esac
