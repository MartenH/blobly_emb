#!/usr/bin/env bash
# boot_bench.sh [node ...] — the field update of each system_full CAN node through its own
# bootloader, end to end on the bench (docs/bootloader.md P3; docs/um/build-and-flash.md §2):
#   1. build the node's image containers at a NEW sw_version     (make image, boot/boot.mk)
#   2. the application hands over to its bootloader              (boot_handoff.lua, BOOT_PHASE=handoff)
#   3. 0x29 + erase + transfer + check + mark + reset            (blobly_net cmd/flash, the field .img)
#   4. the new image runs, and says so in its version DID 0xF195 (boot_handoff.lua, BOOT_PHASE=verify)
# The boards must already run behind their bootloaders (`make -C nodes/<node> flash SERIAL=<sn>` once;
# domain also `make -C nodes/domain_m4 flash`). Nothing here touches SWD.
#
#   BLOBLY_NET=/path/to/blobly_net examples/system_full/test/boot_bench.sh [domain sysnode zone_a]
#
# Env: VERSION (default: seconds since 2026-01-01, so every run is new), IFACE_compute / IFACE_edge
# (the cmd/flash destinations of the two buses; default the bench CANsub, as diag_bench.blobnet).
# Exit: 0 every node passed, 1 a step failed.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
sys=$(dirname "$here")
: "${BLOBLY_NET:?set BLOBLY_NET to the blobly_net checkout}"
VERSION=${VERSION:-$(( $(date +%s) - 1767225600 ))}
IFACE_compute=${IFACE_compute:-cansub:e5a16adf/2@500000}
IFACE_edge=${IFACE_edge:-cansub:e5a16adf/1@500000/2000000}
nodes=("$@"); [ ${#nodes[@]} = 0 ] && nodes=(domain sysnode zone_a)

lua() { # phase node [version]
	BOOT_PHASE=$1 BOOT_NODES=$2 BOOT_VERSION=${3:-} v -enable-globals \
		-path "@vlib|@vmodules|$BLOBLY_NET/modules" run "$BLOBLY_NET/cmd/script/run.v" "$here/boot_handoff.lua"
}

for n in "${nodes[@]}"; do
	case $n in
		domain) bus=compute req=7B0 rsp=7B8 ;;
		sysnode) bus=compute req=7A0 rsp=7A8 ;;
		zone_a) bus=edge req=7C0 rsp=7C8 ;;
		*) echo "boot_bench: no node $n (domain sysnode zone_a; tcu is Ethernet-only — no CAN bootloader reaches it)"; exit 1 ;;
	esac
	iface_var=IFACE_$bus
	echo "== $n: image v$VERSION"
	make -C "$sys/nodes/$n" image SW_VERSION="$VERSION" >/dev/null || { echo "FAIL $n: make image"; exit 1; }
	echo "== $n: handoff"
	lua handoff "$n" || { echo "FAIL $n: handoff"; exit 1; }
	echo "== $n: flash over ${!iface_var}"
	(cd "$BLOBLY_NET" && v -enable-globals -path "@vlib|@vmodules|modules" run cmd/flash \
		"${!iface_var}" "$sys/nodes/$n/build/$n.img" 08020000 "$req" "$rsp" "$VERSION") \
		|| { echo "FAIL $n: cmd/flash"; exit 1; }
	echo "== $n: verify"
	lua verify "$n" "$VERSION" || { echo "FAIL $n: the new image does not run"; exit 1; }
	echo "PASS $n: v$VERSION flashed through its bootloader"
done
