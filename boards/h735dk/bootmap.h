/* boards/h735dk/bootmap.h — the boot manager <-> application contract on this
 * board (docs/bootloader.md): flash layout + the no-init handshake cells. The
 * generator, the boot image, and the app glue all include THIS — the numbers
 * appear nowhere else.
 *
 * The H735 is SINGLE-BANK (1 MB, 8 sectors x 128 KB) — the same boot/app split
 * as the h755zi single-bank map, minus bank 2. boot = sector 0 (128 KB, never
 * field-updated); app region = sectors 1..7. The app's 64-byte image header
 * sits at APP_BASE; its vector table at APP_BASE + 0x400 (VTOR needs >=
 * 512-byte alignment on this core — mkimage pads header->vectors, the CRC
 * covers the pad).
 *
 * Atomic activation degrades here: with one bank there is no read-while-write
 * A/B swap, so the boot uses valid-mark-last (the mark word is programmed only
 * after the image verifies — a torn transfer leaves it unmarked = not bootable).
 * See docs/bootloader.md P4. */
#ifndef BLOBLY_H735_BOOTMAP_H
#define BLOBLY_H735_BOOTMAP_H

#define BOOT_BASE 0x08000000u
#define BOOT_SIZE 0x00020000u /* sector 0 */
#define APP_BASE 0x08020000u
#define APP_SIZE 0x000E0000u /* sectors 1..7 */
#define APP_VECTORS (APP_BASE + 0x400u)

/* Handshake cells in D3 SRAM4 (0x38000000, 16 KB) — survive NVIC_SystemReset,
 * garbage after POR (that's what the magics are for). Single-core: no xcore.h
 * map to dodge. Layout: [magic, arg] each. */
#define BOOTCELL_REQ_ADDR 0x38000FE0u /* app -> boot: enter programming mode */
#define BOOTCELL_REQ_MAGIC 0x544F4F42u /* 'BOOT' */
#define BOOTCELL_INFO_ADDR 0x38000FF0u /* boot -> app: reason, bl version */
#define BOOTCELL_INFO_MAGIC 0x46495442u /* 'BTIF' */

/* boot_info reasons */
#define BOOT_REASON_NORMAL 0u
#define BOOT_REASON_PROGRAMMED 1u /* app was (re)flashed this cycle */
#define BOOT_REASON_NO_APP 2u     /* stayed in boot: no valid image */

#endif
