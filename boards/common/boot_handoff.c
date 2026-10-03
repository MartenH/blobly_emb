/* boot_handoff.c — the application's side of the programming handoff ([boot], docs/bootloader.md
 * P3): what the generated comm thread asks the board when a tester's 0x10 02 has been answered.
 * Linked by gen/loom_build.mk (LOOM_GLUE_SRCS) into a [boot] node only; the board's bootmap.h
 * says where the cells and the app slot are.
 *
 *   boot_handoff_request — the boot request cell, written right before the reset (the answer is
 *                          already on the wire, REQ-BOOT-012), so the boot manager stays and
 *                          serves the programming session instead of jumping back here.
 *   boot_handoff_ok      — the application's conditions (REQ-BOOT-015): 0 answers the request
 *                          conditionsNotCorrect (0x22) and nothing is handed off. WEAK and allowing:
 *                          only the application knows its state model, and it overrides this in
 *                          its own glue (target_ext.c).
 *   boot_image_version   — the running image's sw_version, from the header at APP_BASE the boot
 *                          manager verified before it jumped; 0 when no header is there. */
#include <stdint.h>
#if !__has_include("bootmap.h")
#error "[boot]: this board has no bootmap.h — no bootloader layout to hand over to (docs/bootloader.md)"
#endif
#include "bootcell.h"

void boot_handoff_request(void) {
	bootcell_request(BOOTCELL_REQ_HANDOFF);
}

__attribute__((weak)) int boot_handoff_ok(void) {
	return 1;
}

#define BOOT_HDR_MAGIC 0x54424C42u /* 'BLBT' (boot/boot.v magic) */

uint32_t boot_image_version(void) {
	const volatile uint32_t *h = (const volatile uint32_t *)APP_BASE;
	if (h[0] != BOOT_HDR_MAGIC) return 0;
	return h[4]; /* offset 16: sw_version */
}
