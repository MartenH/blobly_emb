#!/usr/bin/env bash
# boot_bench.sh [entry ...] — the field update of each system_full node through its own
# bootloader, end to end on the bench — over CAN (domain, sysnode, zone_a) and over DoIP
# (sysnode-doip: the H735 on the LAN at SYSNODE_ADDR, through test/diag_bench.blobnet) (docs/bootloader.md P3;
# docs/um/build-and-flash.md §2): build
# each node's image containers at a NEW sw_version (make image, boot/boot.mk), then ONE Lua suite
# (boot_handoff.lua): the handoff, blobly_net's flash.program over the handed-off connection
# (net #388), and the new image's version DID. The boards must already run behind their bootloaders
# (`make -C nodes/<node> flash SERIAL=<sn>` once; domain also `make -C nodes/domain_m4 flash`).
# Nothing here touches SWD.
#
#   BLOBLY_NET=/path/to/blobly_net examples/system_full/test/boot_bench.sh [domain sysnode zone_a]
#
# Env: VERSION (default: seconds since 2026-01-01, so every run is new); BOOT_RECORD (default
# test/build/boot_bench.log; empty: none): the CAN buses recorded through the run, and a last test
# that no other tester sent on the nodes' request ids meanwhile — ONE tester per id pair, so stop
# anything else that diagnoses these nodes (blobly_gw's otad reads them at every server poll, 120 s
# on the bench; emb#407).
# Exit: the suite's.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
sys=$(dirname "$here")
: "${BLOBLY_NET:?set BLOBLY_NET to the blobly_net checkout}"
. "$here/../../../scripts/blobly_net_check.sh"
require_blobly_net "$BLOBLY_NET" || exit 1 # before any image is built
VERSION=${VERSION:-$(( $(date +%s) - 1767225600 ))}
nodes=("$@"); [ ${#nodes[@]} = 0 ] && nodes=(domain sysnode zone_a sysnode-doip)
for n in "${nodes[@]}"; do
	case $n in
		domain | sysnode | zone_a | sysnode-doip) ;;
		*) echo "boot_bench: no entry $n (domain sysnode zone_a sysnode-doip)"; exit 1 ;;
	esac
	node=${n%-doip}
	make -C "$sys/nodes/$node" image SW_VERSION="$VERSION" >/dev/null || { echo "FAIL $n: make image"; exit 1; }
done
list=$(IFS=,; echo "${nodes[*]}")
rec=${BOOT_RECORD-$here/build/boot_bench.log}
if [ -n "$rec" ]; then
	case $rec in /*) ;; *) rec=$PWD/$rec ;; esac # the suite resolves a relative path from the script
	mkdir -p "$(dirname "$rec")"
fi
BOOT_RECORD=$rec BOOT_PHASE=flash BOOT_NODES=$list BOOT_VERSION=$VERSION v -enable-globals \
	run "$BLOBLY_NET/cmd/script/run.v" "$here/boot_handoff.lua"
