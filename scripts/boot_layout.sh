#!/usr/bin/env bash
# boot_layout.sh <cc> <board_dir> <what> — a board's bootloader flash layout, read from its
# bootmap.h (the ONE place the numbers live) by the C preprocessor, for boot/boot.mk:
#   boot-size   the boot region (BOOT_SIZE), for the boot image's link limit
#   boot-base   where the boot image is written (BOOT_BASE)
#   app-base    where the image container goes (APP_BASE)
#   app-ld      the application's link flags: its vectors at APP_VECTORS, its length the slot less
#               the vector pad and the 64-byte signature mkimage --sign appends
set -euo pipefail
cc=$1 board=$2 what=$3
vals=$(printf 'BOOT_BASE BOOT_SIZE APP_BASE APP_SIZE APP_VECTORS\n' |
	$cc -E -P -x c -include "$board/bootmap.h" - | tr -d 'u()' | tail -1)
read -r boot_base boot_size app_base app_size app_vectors <<<"$vals"
hex() { printf '0x%X' "$(($1))"; }
case $what in
	boot-size) hex "$boot_size" ;;
	boot-base) hex "$boot_base" ;;
	app-base) hex "$app_base" ;;
	app-ld)
		pad=$((app_vectors - app_base))
		echo "-Wl,--defsym,__flash_base__=$(hex "$app_vectors") -Wl,--defsym,__flash_len__=$(hex $((app_size - pad - 64)))" ;;
	*) echo "boot_layout.sh: unknown '$what'" >&2; exit 2 ;;
esac
