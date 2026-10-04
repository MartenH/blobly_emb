/* boards/h723/bootmap.h — the boot manager <-> application contract on this
 * board (docs/bootloader.md): flash layout + the no-init handshake cells. The
 * generator, the boot image, and the app glue all include THIS — the numbers
 * appear nowhere else.
 *
 * The H723ZG is SINGLE-BANK (1 MB, 8 sectors x 128 KB) — the H735's geometry and the same
 * boot/app split as the H735 (boards/h735dk/bootmap.h), one flash driver (boards/common/flash_h72x.c).
 * boot = sector 0 (128 KB, never field-updated); app region = sectors 1..5; the NvM journal =
 * sectors 6 + 7 (below), outside the app region, so neither a download nor `make flash` erases it. The app's 64-byte image header
 * sits at APP_BASE; its vector table at APP_BASE + 0x400 (VTOR wants the
 * table's size rounded up to a power of two — 179 words, so 1 KiB; checked by
 * tools/vectab/vectab_test.v — mkimage pads header->vectors, the CRC
 * covers the pad).
 *
 * Atomic activation degrades here: with one bank there is no read-while-write
 * A/B swap, so the boot uses valid-mark-last (the mark word is programmed only
 * after the image verifies — a torn transfer leaves it unmarked = not bootable).
 * See docs/bootloader.md P4. */
#ifndef BLOBLY_H723_BOOTMAP_H
#define BLOBLY_H723_BOOTMAP_H

#define BOOT_BASE 0x08000000u
#define BOOT_SIZE 0x00020000u /* sector 0 */
#define APP_BASE 0x08020000u
#define APP_SIZE 0x000A0000u /* sectors 1..5 (640 KB) */
#define APP_VECTORS (APP_BASE + 0x400u)

/* The NvM journal's sector pair (docs/nvm.md; boards/common/nvm_map.c): sectors 6 + 7. ONE bank,
 * so a program or an erase stalls every instruction fetch until it completes — a 32-byte record
 * for microseconds, an erase for the sector's erase time (about a second). The append path never
 * erases; a node without NM erases a sector a compaction left behind at boot, before the kernel
 * starts (its quiet point, once per sector fill), one with NM at its sleep edges. */
#define NVM_A_ADDR 0x080C0000u /* sector 6 */
#define NVM_B_ADDR 0x080E0000u /* sector 7 */
#define NVM_SIZE 0x00020000u   /* 128 KB each */

/* Handshake cells in D3 SRAM4 (0x38000000, 16 KB) — survive NVIC_SystemReset,
 * garbage after POR (that's what the magics are for). Single-core: no xcore.h
 * map to dodge. Layout: [magic, arg] each. */
/* 0x38000FC0..0x38000FD3: the diagnostic server's keep cell (boards/common/diag_board.c) */
#define BOOTCELL_REQ_ADDR 0x38000FE0u /* app -> boot: enter programming mode */
#define BOOTCELL_REQ_MAGIC 0x544F4F42u /* 'BOOT' */
#define BOOTCELL_INFO_ADDR 0x38000FF0u /* boot -> app: reason, bl version */
#define BOOTCELL_INFO_MAGIC 0x46495442u /* 'BTIF' */

/* boot_info reasons */
#define BOOT_REASON_NORMAL 0u
#define BOOT_REASON_PROGRAMMED 1u /* app was (re)flashed this cycle */
#define BOOT_REASON_NO_APP 2u     /* stayed in boot: no valid image */

#endif
