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
	# how V runs is an input: another define leaves the bootloader out of date
	if make -C "$d" -q boot BOOT_VDEFS="-d boot_deps_check" >/dev/null 2>&1; then
		echo "boot_deps_check: $d: the bootloader ignores a change of V flags"
		fail=1
	fi
	make -C "$d" boot >/dev/null 2>&1 || { echo "boot_deps_check: $d: rebuild failed"; fail=1; }
	# without its record (boot/boot.mk v_deps) the generated C is not current, whatever its age
	rm -f "$d/build/boot/boot.c.d"
	if make -C "$d" -q boot >/dev/null 2>&1; then
		echo "boot_deps_check: $d: the bootloader's C without its record reads as up to date"
		fail=1
	fi
	make -C "$d" boot >/dev/null 2>&1 || { echo "boot_deps_check: $d: rebuild failed"; fail=1; }
	# The app-slot layout (boot/boot.mk boot_layout) is asked of the whole $(CC) as it runs: a
	# compiler written behind an assignment still gets it, and a host-only `make gen` with no
	# compiler at all still generates. Both parses sign another command, so the signatures are
	# kept, with their times, and put back.
	find "$d/build" -name '*.sig' -exec cp -p {} {}.keep \;
	ld=$(make -s -C "$d" --no-print-directory --eval 'boot-deps-layout: ; @echo "$(call boot_layout,app-ld)"' boot-deps-layout CC='BOOT_DEPS_CHECK=1 arm-none-eabi-gcc' 2>/dev/null | tail -1)
	case $ld in
		*__flash_base__=*) ;;
		*) echo "boot_deps_check: $d: a CC behind an assignment gets no app-slot layout ('$ld')"; fail=1 ;;
	esac
	make -C "$d" gen CC=boot-deps-check-no-such-gcc >/dev/null 2>&1 || { echo "boot_deps_check: $d: make gen fails with no cross compiler"; fail=1; }
	find "$d/build" -name '*.sig' | while read -r f; do [ -f "$f.keep" ] || rm -f "$f"; done
	find "$d/build" -name '*.sig.keep' | while read -r k; do mv -f "$k" "${k%.keep}"; done
	make -C "$d" -q boot >/dev/null 2>&1 || { echo "boot_deps_check: $d: the bootloader is out of date with its signatures restored"; fail=1; }
	echo "boot_deps_check: $d ok"
done
exit $fail
