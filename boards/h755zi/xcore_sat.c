/* xcore_sat.c — the satellite (CM4) half of the owner -> satellite signals (xcore.h, the
 * owner-written window). The reader state is the caller's: st[0] the owner nonce it was filled
 * under, st[1] the xioc_n read sequence, st[2..] the last-good lanes. Plain loads and barriers
 * only (xioc.h), so the host test runs it. */
#include <stdint.h>
#include "xcore.h"
#include "xioc.h"
#include "xcore_gen.h"

static void down_reset(uint32_t words, uint32_t *st) {
	st[1] = 0u;
	for (uint32_t i = 0; i < words; i++) {
		st[2u + i] = 0u;
	}
}

/* 1 = the lanes hold a value the owner published in its current boot; 0 = default, lanes zero */
int xcore_down_read(uint32_t off, uint32_t words, uint32_t *st) {
	uint32_t ack = XIOC_LD((volatile uint32_t *)(uintptr_t)XCORE_OW_ACK_ADDR);
	uint32_t nonce = XIOC_LD((volatile uint32_t *)(uintptr_t)XCORE_OW_NONCE_ADDR);
	/* gate closed: retracted, a different build, or a torn view of an owner re-init */
	if (ack == 0u || ack != xcore_ow_ack(nonce ^ XCORE_LAYOUT_ID)) {
		st[0] = 0u;
		down_reset(words, st);
		return 0;
	}
	XIOC_DMB();
	/* a new owner boot starts from the default, never the previous boot's value */
	if (st[0] != nonce) {
		st[0] = nonce;
		down_reset(words, st);
	}
	(void)xioc_n_read((xioc_n_t *)(uintptr_t)(XCORE_OW_CH_ADDR + off), &st[1], &st[2], words);
	/* the gate again, after the read — fresh or not: an owner re-init that began meanwhile (it
	 * retracts the ack first) must leave neither a new copy nor the kept value standing under the
	 * old nonce */
	XIOC_DMB();
	if (XIOC_LD((volatile uint32_t *)(uintptr_t)XCORE_OW_ACK_ADDR) != ack ||
	    XIOC_LD((volatile uint32_t *)(uintptr_t)XCORE_OW_NONCE_ADDR) != nonce) {
		st[0] = 0u;
		down_reset(words, st);
		return 0;
	}
	return st[1] != 0u;
}

/* this core's total busy share (basis points, 0.01 %; -1 = not measurable) into its XCORE_BUSY_ADDR slot with
 * the next publish count, which the owner reads (xcore_owner.c) — one writer per slot, this core */
void xcore_busy_pub(int core, int bp) {
	static uint32_t n;
	if (core < 0 || core >= 8)
		return;
	n++;
	if ((n & 0xFFFFu) == 0u)
		n++; /* 0 is the owner's 'never published' */
	uint32_t v = (bp < 0 ? 0xFFFFu : (uint32_t)bp & 0xFFFFu) | (n << 16);
	XIOC_ST((volatile uint32_t *)(uintptr_t)XCORE_BUSY_ADDR + core, v);
}
