#!/usr/bin/env bash
# boot_bench.sh [entry ...] — the field update of each system_full node through its own
# bootloader, end to end on the bench — over CAN (domain, sysnode, zone_a) and over DoIP
# (sysnode-doip: the H735 on the LAN at 192.168.0.50) (docs/bootloader.md P3; docs/um/build-and-flash.md §2): build
# each node's image containers at a NEW sw_version (make image, boot/boot.mk), then ONE Lua suite
# (boot_handoff.lua): the handoff, blobly_net's flash.program over the handed-off connection
# (net #388), and the new image's version DID. The boards must already run behind their bootloaders
# (`make -C nodes/<node> flash SERIAL=<sn>` once; domain also `make -C nodes/domain_m4 flash`).
# Nothing here touches SWD.
#
#   BLOBLY_NET=/path/to/blobly_net examples/system_full/test/boot_bench.sh [domain sysnode zone_a]
#
# Env: VERSION (default: seconds since 2026-01-01, so every run is new). Exit: the suite's.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
sys=$(dirname "$here")
: "${BLOBLY_NET:?set BLOBLY_NET to the blobly_net checkout}"
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
BOOT_PHASE=flash BOOT_NODES=$list BOOT_VERSION=$VERSION v -enable-globals \
	-path "@vlib|@vmodules|$BLOBLY_NET/modules" run "$BLOBLY_NET/cmd/script/run.v" "$here/boot_handoff.lua"
