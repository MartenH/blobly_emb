#!/usr/bin/env bash
# auth_target_check.sh — cross-build a ThreadX node that unlocks by 0x29 AUTHENTICATION (ACR with
# Ed25519, [uds] access = "authentication", docs/diagnostics.md §3.1). No committed image has that
# shape: system_full's nodes unlock by 0x27 (the bench suites use it), and examples/uds_auth is a
# host example. So nothing else links bcrypto's verifier into an APPLICATION, fills the per-level
# keys in a freestanding init path, or puts the 16 KB comm stack on silicon's memory map. This builds
# system_full's zone_a (ThreadX, [nvm], DIDs gated at level 1, no DoIP) with its 0x27 reference key
# swapped for the dev tester key as a 0x29 auth key, and holds the image to the target's gates: it
# links, lint_vinit (zone_a's Makefile runs it on the C) passes, nothing reaches an allocator
# (check_no_heap), the glue carries udsauth and the 16 KB stack, and the image runs the stepped
# verify (udsauth's step over bcrypto.VerifyJob — a slice per pass, never a whole verify). The comm thread's stack use is
# printed (-fstack-usage) for review, not gated.
#
# Builds a scratch copy of the tracked tree, so the checkout is never touched. Needs the ARM
# toolchain and `make deps` (third_party/), as the cross job has.
#
#   scripts/auth_target_check.sh
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
[ -d "$repo/third_party/threadx" ] || { echo "auth_target_check: run 'make deps' first" >&2; exit 2; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# the tracked tree as it stands in the working tree (edits, new files; a deleted one skipped),
# plus the third-party sources by link
(cd "$repo" && git ls-files -z --cached --others --exclude-standard --deduplicate \
	| while IFS= read -r -d '' f; do
		case "$f" in third_party/*) continue ;; esac
		if [ -f "$f" ] || [ -L "$f" ]; then printf '%s\0' "$f"; fi
	done | xargs -0 cp --parents -t "$tmp")
ln -s "$repo/third_party" "$tmp/third_party"

node="$tmp/examples/system_full/nodes/zone_a"
grep -q '^security_key      = "reference"$' "$node/ecu.toml" \
	|| { echo "auth_target_check: zone_a's ecu.toml changed shape (no 0x27 reference key line)" >&2; exit 1; }
sed -i 's/^security_key      = "reference"$/access            = "authentication"\nauth_keys         = { "1" = "reference" }/' "$node/ecu.toml"
grep -q '^access            = "authentication"$' "$node/ecu.toml" \
	|| { echo "auth_target_check: the variant was not written" >&2; exit 1; }

# every compile also writes its frames' sizes (-fstack-usage), for the summary below
printf '\nCFLAGS += -fstack-usage\n' >> "$node/Makefile"
make -C "$node" all
glue="$node/gen/loom_gen.v"
grep -q 'import comm.udsauth' "$glue" || { echo "auth_target_check: the glue does not import udsauth" >&2; exit 1; }
grep -q 'g_diag.server.auth = g_auth_keys.ops()' "$glue" || { echo "auth_target_check: the keys are not wired" >&2; exit 1; }
grep -q 'g_comm_stack \[16384\]u8' "$glue" || { echo "auth_target_check: the comm stack is not 16 KB" >&2; exit 1; }
elf=$(ls "$node"/build/*.elf | head -1)
"$repo/scripts/check_no_heap.sh" "$elf"
# the proof is verified a slice per pass: the seam's step callback (udsauth, over bcrypto.VerifyJob,
# which -Os may inline into it) is in the image, and no whole-verify callback is
syms="$(arm-none-eabi-nm "$elf")"
grep -q ' udsauth__keys_step$' <<<"$syms" \
	|| { echo "auth_target_check: udsauth's step is not in the image — the stepped verify is not what runs" >&2; exit 1; }
if grep -q ' udsauth__keys_verify$' <<<"$syms"; then
	echo "auth_target_check: a whole-verify callback is in the image" >&2; exit 1
fi
# the verifier's frames, for review: the deepest stack users in the image
mapfile -t sus < <(find "$node" -name '*.su')
if [ ${#sus[@]} -gt 0 ]; then
	echo "auth_target_check: the deepest frames (-fstack-usage):"
	cat "${sus[@]}" | sort -t$'\t' -k2 -n -r | head -12 | sed 's/^/  /'
fi
echo "auth_target_check: a ThreadX node authenticating with 0x29 builds, lint_vinit and no-heap clean"
