/* bootcell.h — the boot request / boot info cells as both sides of the handoff read and write them
 * (docs/bootloader.md, "The handoff, both directions"): the application asks for the programming
 * session (boot_handoff.c, a shell `boot` command), the boot manager takes the request and leaves
 * its reason for the app (the boot images' glue). The ADDRESSES and the app slot are the board's
 * (bootmap.h); this is the one statement of what the cells hold, so the two sides cannot drift.
 * Both cells sit in D3 SRAM4, which a system reset leaves alone and a power-on fills with garbage —
 * hence a magic each, and a request consumed when read. */
#ifndef BLOBLY_BOOTCELL_H
#define BLOBLY_BOOTCELL_H

#include <stdint.h>
#include "bootmap.h"

/* why the application asked (the request cell's argument) */
#define BOOTCELL_REQ_SHELL 1u   /* a bench `boot` command: no tester session was promised */
#define BOOTCELL_REQ_HANDOFF 2u /* 0x10 02 answered 50 02 over the bus: the tester holds a programming session */
#define BOOTCELL_REQ_HANDOFF_NET 3u /* ... over DoIP: the session is the network tester's, who reconnects */

/* app -> boot: enter (and stay in) programming mode at the next reset */
static inline void bootcell_request(uint32_t why) {
	volatile uint32_t *c = (volatile uint32_t *)BOOTCELL_REQ_ADDR;
	c[1] = why; /* first: the magic that makes the pair valid lands last */
	c[0] = BOOTCELL_REQ_MAGIC;
	__asm__ volatile("dsb");
}

/* boot: the pending request's kind (0 = none) — consumed, so a later reset decides afresh. A kind
 * this header does not name is a request with no promise behind it. */
static inline uint32_t bootcell_take_request(void) {
	volatile uint32_t *c = (volatile uint32_t *)BOOTCELL_REQ_ADDR;
	if (c[0] != BOOTCELL_REQ_MAGIC) return 0;
	uint32_t why = c[1];
	c[0] = 0;
	return (why == BOOTCELL_REQ_HANDOFF || why == BOOTCELL_REQ_HANDOFF_NET) ? why : BOOTCELL_REQ_SHELL;
}

/* boot -> app: why the application is running (BOOT_REASON_*) */
static inline void bootcell_set_info(uint32_t reason) {
	volatile uint32_t *c = (volatile uint32_t *)BOOTCELL_INFO_ADDR;
	c[1] = reason;
	c[0] = BOOTCELL_INFO_MAGIC;
}

#endif
