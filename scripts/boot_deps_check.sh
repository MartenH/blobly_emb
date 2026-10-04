#!/usr/bin/env bash
# boot_deps_check.sh — a [boot] node's bootloader is remade when ANY source it was built from
# changes, including the ones only the C compiler knows: headers, and the backend can_backend.c
# includes textually (driver/can/can_fdcan.c). boot/boot.mk takes those from the compiler's own
# dependency output; this asks make. Run after the cross builds (the CI cross job does).
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
for ecu in examples/*/nodes/*/ecu.toml examples/*/ecu.toml; do
	grep -qx '\[boot\]' "$ecu" || continue
	d=$(dirname "$ecu")
	# up to date first: the sources touched below are shared, so the previous node's check left
	# this one's bootloader stale
	make -C "$d" boot >/dev/null 2>&1 || { echo "boot_deps_check: $d: boot does not build"; fail=1; continue; }
	make -C "$d" -q boot >/dev/null 2>&1 || { echo "boot_deps_check: $d: boot still out of date after a build"; fail=1; continue; }
	for src in driver/can/can_fdcan.c driver/can/can_port.h boards/common/bootcell.h comm/diag/step.v comm/isotp/isotp.v driver/doipnet/doipnet.v scripts/vdeps.sh tools/tools.mk; do
		# a V module only the DoIP boot compiles in (driver/doipnet) is no dependency of a bus-only one
		case $src in
			*.v) grep -qx "./$src" "$d/build/boot/boot.c.files" 2>/dev/null || continue ;;
		esac
		touch "$src"
		if make -C "$d" -q boot >/dev/null 2>&1; then
			echo "boot_deps_check: $d: touching $src leaves the bootloader up to date — a dependency is missing"
			fail=1
		fi
		make -C "$d" boot >/dev/null 2>&1 || { echo "boot_deps_check: $d: rebuild failed"; fail=1; }
	done
	echo "boot_deps_check: $d ok"
done
exit $fail
