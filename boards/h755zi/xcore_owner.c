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
static uint32_t g_busy_seen[8]; /* each busy slot's publish count at the last load window */
static uint8_t g_busy_live[8];  /* it moved in that window: the core is reporting */

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
	/* no satellite has reported its load in this boot yet: retained slots must not read as one */
	for (uint32_t c = 0; c < 8u; c++) {
		XIOC_ST((volatile uint32_t *)(uintptr_t)XCORE_BUSY_ADDR + c, 0xFFFFu);
		g_busy_live[c] = 0u;
	}
}

/* once per load window (trace_hooks.c core_load_tick, the owner's comm thread): a core is reporting
 * while its publish count moved since the last window */
void xcore_busy_watch(void) {
	for (uint32_t c = 0; c < 8u; c++) {
		uint32_t n = XIOC_LD((volatile uint32_t *)(uintptr_t)XCORE_BUSY_ADDR + c) >> 16;
		g_busy_live[c] = n != 0u && n != g_busy_seen[c];
		g_busy_seen[c] = n;
	}
}

/* a satellite core's total busy share (basis points, 0.01 %), -1 = not reported, or not since the last window */
int xcore_busy_get(int core) {
	if (core < 0 || core >= 8 || !g_busy_live[core])
		return -1;
	uint32_t bp = XIOC_LD((volatile uint32_t *)(uintptr_t)XCORE_BUSY_ADDR + core) & 0xFFFFu;
	return bp == 0xFFFFu ? -1 : (int)bp;
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
