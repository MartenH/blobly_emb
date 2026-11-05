/* xcore_owner.c — the owner (CM7) half of the owner -> satellite signals (xcore.h, the
 * owner-written window). Generated owner boot calls xcore_owner_begin, xcore_ow_init per channel
 * and xcore_owner_commit before it releases the satellite's clocks; the writing thread then
 * publishes with xcore_opub_n. Plain stores and barriers only (xioc.h), so the host test runs it. */
#include <stdint.h>
#include "xcore.h"
#include "xioc.h"
#include "xcore_gen.h"

static uint32_t g_ow_nonce; /* this owner boot's nonce */
static uint32_t g_ow_seed;  /* this owner boot's xioc_n sequence seed */

static xioc_n_t *ow_chan(uint32_t off) {
	return (xioc_n_t *)(uintptr_t)(XCORE_OW_CH_ADDR + off);
}

/* retract the gate, then take a new odd nonce (retained cell) and derive the sequence seed */
void xcore_owner_begin(void) {
	volatile uint32_t *ack = (volatile uint32_t *)(uintptr_t)XCORE_OW_ACK_ADDR;
	volatile uint32_t *nonce = (volatile uint32_t *)(uintptr_t)XCORE_OW_NONCE_ADDR;
	XIOC_ST(ack, 0u);
	XIOC_DMB();
	g_ow_nonce = (XIOC_LD(nonce) + 2u) | 1u;
	XIOC_ST(nonce, g_ow_nonce);
	g_ow_seed = (g_ow_nonce * 2654435761u) | 1u;
}

void xcore_ow_init(uint32_t off, uint32_t words) {
	xioc_n_init(ow_chan(off), words, g_ow_seed);
}

/* open the gate for this build and this boot, after every channel is initialised */
void xcore_owner_commit(void) {
	XIOC_DMB();
	XIOC_ST((volatile uint32_t *)(uintptr_t)XCORE_OW_ACK_ADDR, xcore_ow_ack(g_ow_nonce ^ XCORE_LAYOUT_ID));
	XIOC_DMB();
}

void xcore_opub_n(uint32_t off, const uint32_t *src) {
	xioc_n_write(ow_chan(off), src);
}
