#!/usr/bin/env bash
# glue_link_check.sh — cross-link a MULTI-THREAD GATEWAY: system_full's sysnode (three FDCAN
# buses, routes, DoIP) with a second app thread carrying an FB of its own. No committed image has
# that shape, and it is the one that once could not link: the glue with the multi-bus Rx had no
# per-thread load cells and the glue with the load cells had no multi-bus Rx (#359). The host
# test (tools/loom2v/threadx_makefiles_test.v) pins that boards/common/comm_glue.c defines every
# symbol the generator can declare; this proves one such image actually links.
#
# Builds a scratch copy of the tracked tree, so the checkout is never touched. Needs the ARM
# toolchain and `make deps` (third_party/), as the cross job has.
#
#   scripts/glue_link_check.sh
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
[ -d "$repo/third_party/threadx" ] || { echo "glue_link_check: run 'make deps' first" >&2; exit 2; }
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

node="$tmp/examples/system_full/nodes/sysnode"
# a second app thread in the gateway partition ...
awk '{ print } /^  name = "gw_main"$/ { print ""; print "  [[partition.thread]]"; print "  name = \"gw_aux\"" }' \
	"$node/ecu.toml" > "$node/ecu.toml.new"
mv "$node/ecu.toml.new" "$node/ecu.toml"
grep -q 'name = "gw_aux"' "$node/ecu.toml" || { echo "glue_link_check: sysnode's ecu.toml changed shape" >&2; exit 1; }
# ... with an FB on it (appended LAST: sysnode's ecu.toml keeps its partition and FBs at the end)
cat >> "$node/ecu.toml" <<'EOF'

[[fb]]
name   = "GwTick"
thread = "gw_aux"

  [[fb.handler]]
  name      = "on_100ms"
  period_ms = 100 # trailing comment terminates the nested block (vlang/v#27684)
EOF
cat > "$node/app/gw_tick.v" <<'EOF'
module app

import ports

pub struct GwTick {
pub mut:
	n u32
}

pub fn (mut fb GwTick) on_100ms(inp ports.GwTickIn, mut out ports.GwTickOut) {
	fb.n++
}
EOF

make -C "$node" all
grep -q 'g_sched_gw_aux' "$node/gen/loom_gen.v" || { echo "glue_link_check: the variant did not generate two app threads" >&2; exit 1; }
grep -q 'comm_rx_irq_enable_idx' "$node/gen/loom_gen.v" || { echo "glue_link_check: the variant is not a gateway" >&2; exit 1; }
echo "glue_link_check: a multi-thread gateway links"
