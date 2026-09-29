/* diag_board.c — the board seam of a node's diagnostic server on the target (docs/diagnostics.md).
 * comm/uds carries no key and touches no register: the generated comm thread asks the board for a
 * seed, a reset and a cell that survives it, and the OEM's glue for a key verdict.
 *
 * SecurityAccess (0x27, decision D5):
 *   diag_sa_init   — the STM32H7 true RNG's clock (HSI48) and enable, once, from the comm
 *                    thread's init before its loop: never inside a request. A failure is
 *                    remembered, so a dead RNG costs one bounded wait, not one per request.
 *   diag_sa_seed   — `n` random bytes. WEAK: an HSM replaces it. A seed or clock error is
 *                    recovered by the reference manual's sequence (clear the flags, restart the
 *                    RNG) and this request answers "no seed" (the server: conditionsNotCorrect).
 *   diag_sa_key_ok — NOT HERE, deliberately. The OEM's node glue supplies it; a node that gates a
 *                    DID and has none fails to LINK, naming the symbol. blobly_net's public
 *                    reference key is opted into by name (`[[isotp]] security_key = "reference"`)
 *                    and is then comm/uds's own, in V — never a silent default in an image. */
#include <stdint.h>

#define RCC_CR_R       (*(volatile uint32_t *)0x58024400u)
#define RCC_D2CCIP2R_R (*(volatile uint32_t *)0x58024454u)
#define RCC_AHB2ENR_R  (*(volatile uint32_t *)0x580244DCu)
#define RNG_CR_R       (*(volatile uint32_t *)0x48021800u)
#define RNG_SR_R       (*(volatile uint32_t *)0x48021804u)
#define RNG_DR_R       (*(volatile uint32_t *)0x48021808u)

#define RNG_CR_RNGEN (1u << 2)
#define RNG_SR_DRDY  (1u << 0)
#define RNG_SR_CECS  (1u << 1)
#define RNG_SR_SECS  (1u << 2)

static int g_sa_rng = 0; /* 0 = not set up, 1 = running, -1 = failed at init */

int diag_sa_init(void) {
	if (g_sa_rng != 0) return g_sa_rng > 0;
	RCC_CR_R |= (1u << 12); /* HSI48ON */
	for (uint32_t t = 0; !(RCC_CR_R & (1u << 13)); t++) {
		if (t > 2000000u) {
			g_sa_rng = -1; /* HSI48RDY never came: remembered */
			return 0;
		}
	}
	RCC_D2CCIP2R_R &= ~(3u << 8); /* RNGSEL = 00 = HSI48 */
	RCC_AHB2ENR_R |= (1u << 6);    /* RNG kernel+bus clock */
	(void)RCC_AHB2ENR_R;
	RNG_CR_R = RNG_CR_RNGEN; /* clock-error detection on */
	g_sa_rng = 1;
	return 1;
}

/* the reference manual's recovery: clear the interrupt flags, restart the generator; the samples
 * of the failed period are discarded with it */
static void sa_rng_recover(void) {
	RNG_SR_R = 0;
	RNG_CR_R &= ~RNG_CR_RNGEN;
	RNG_CR_R |= RNG_CR_RNGEN;
}

__attribute__((weak)) int diag_sa_seed(uint8_t *out, int n) {
	if (g_sa_rng <= 0) return 0;
	int i = 0;
	while (i < n) {
		uint32_t t = 0;
		for (;;) {
			uint32_t sr = RNG_SR_R;
			if (sr & (RNG_SR_SECS | RNG_SR_CECS)) { /* a seed or clock error stops DRDY */
				sa_rng_recover();
				return 0;
			}
			if (sr & RNG_SR_DRDY) break;
			if (++t > 200000u) return 0;
		}
		uint32_t w = RNG_DR_R;
		for (int b = 0; b < 4 && i < n; b++, i++)
			out[i] = (uint8_t)(w >> (8 * b));
	}
	return 1;
}

/* --- ECUReset (0x11) ---------------------------------------------------------------------- */

/* diag_sys_reset: NVIC_SystemReset (AIRCR key + SYSRESETREQ). Called once the 0x11 answer has
 * left the controller (the comm thread waits for tx_idle, REQ-BOOT-012). Never returns. */
void diag_sys_reset(void) {
	__asm__ volatile("dsb");
	*(volatile uint32_t *)0xE000ED0Cu = (0x5FAu << 16) | (1u << 2);
	for (;;) {
	}
}

/* The KEEP cell: what the diagnostic server must carry across its own reset — the 0x27 failed-key
 * counts, or a reset between guesses would buy fresh attempts. In D3 SRAM4, which a system reset
 * does not clear: just below the boot cells (bootmap.h, 0x38000FE0+) and clear of xcore's map
 * (which ends well below 0x38000F00). Garbage after power-on, so a magic and a check word guard it,
 * and it is consumed when read. Not across a power cycle: that is the journal's (docs/diagnostics.md
 * R6). */
#ifndef DIAG_KEEP_ADDR
#define DIAG_KEEP_ADDR 0x38000FC0u
#endif
#define DIAG_KEEP_MAGIC 0x504B4744u /* 'DGKP' */
#define DIAG_KEEP_N 8

void diag_keep_save(const uint8_t *counts, int n) {
	volatile uint32_t *c = (volatile uint32_t *)DIAG_KEEP_ADDR;
	uint32_t w0 = 0, w1 = 0;
	for (int i = 0; i < n && i < DIAG_KEEP_N; i++) {
		if (i < 4) w0 |= (uint32_t)counts[i] << (8 * i);
		else w1 |= (uint32_t)counts[i] << (8 * (i - 4));
	}
	c[1] = w0;
	c[2] = w1;
	c[3] = ~(w0 ^ w1);
	c[0] = DIAG_KEEP_MAGIC;
}

/* 1 and the counts when the cell holds what diag_keep_save wrote before this reset; 0 otherwise
 * (a power-on, or no reset by the server). Consumed either way. */
int diag_keep_load(uint8_t *counts, int n) {
	volatile uint32_t *c = (volatile uint32_t *)DIAG_KEEP_ADDR;
	uint32_t w0 = c[1], w1 = c[2];
	int ok = c[0] == DIAG_KEEP_MAGIC && c[3] == ~(w0 ^ w1);
	c[0] = 0;
	if (!ok) return 0;
	for (int i = 0; i < n && i < DIAG_KEEP_N; i++)
		counts[i] = (uint8_t)((i < 4 ? w0 >> (8 * i) : w1 >> (8 * (i - 4))) & 0xFFu);
	return 1;
}
