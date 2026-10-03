/* bootcell.h — the boot request / boot info cells as both sides of the handoff read and write them
 * (docs/bootloader.md, "The handoff, both directions"): the application (boot_handoff.c) asks for
 * the programming session, the boot manager takes the request and leaves its reason for the app.
 * The ADDRESSES and the app slot are the board's (bootmap.h); this is the one statement of what the
 * cells hold, so the two sides cannot drift. Both cells sit in D3 SRAM4, which a system reset leaves
 * alone and a power-on fills with garbage — hence a magic each, and a request consumed when read. */
#ifndef BLOBLY_BOOTCELL_H
#define BLOBLY_BOOTCELL_H

#include <stdint.h>
#include "bootmap.h"

/* app -> boot: enter (and stay in) programming mode at the next reset */
static inline void bootcell_request(void) {
	volatile uint32_t *c = (volatile uint32_t *)BOOTCELL_REQ_ADDR;
	c[1] = 0; /* no argument yet; written first, so the magic that makes the pair valid lands last */
	c[0] = BOOTCELL_REQ_MAGIC;
	__asm__ volatile("dsb");
}

/* boot: 1 when a request is pending — consumed, so a later reset decides afresh */
static inline uint32_t bootcell_take_request(void) {
	volatile uint32_t *c = (volatile uint32_t *)BOOTCELL_REQ_ADDR;
	if (c[0] != BOOTCELL_REQ_MAGIC) return 0;
	c[0] = 0;
	return 1;
}

/* boot -> app: why the application is running (BOOT_REASON_*) */
static inline void bootcell_set_info(uint32_t reason) {
	volatile uint32_t *c = (volatile uint32_t *)BOOTCELL_INFO_ADDR;
	c[1] = reason;
	c[0] = BOOTCELL_INFO_MAGIC;
}

#endif
