/* diag_board.c — the board seam of a node's diagnostic server on the target (docs/diagnostics.md).
 * comm/uds carries no key and touches no register: the generated comm thread asks the board for a
 * seed, a reset and a cell that survives it, and the OEM's glue for a key verdict.
 *
 * SecurityAccess (0x27, decision D5):
 *   diag_sa_init   — the STM32H7 true RNG's clock (HSI48) and enable, once, from the comm
 *                    thread's init before its loop: never inside a request. A failure is
 *                    remembered, so a dead RNG costs one bounded wait, not one per request.
 *   diag_sa_seed   — `n` random bytes. WEAK: an HSM replaces it. A seed or clock error is
 *                    recovered by the reference manual's sequence and the seed drawn AGAIN in the
 *                    same request (up to SA_SEED_ATTEMPTS): the health tests flag good noise now
 *                    and then, and a tester must not see that. Only an RNG failing every attempt
 *                    answers "no seed" (the server: conditionsNotCorrect) — a real fault.
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

/* the reference manual's recovery from a seed error; the samples of the failed period are
 * discarded with it. The H72x/H73x RNG restarts through CONDRST (RM0468: CONDRST 1 then 0, wait for
 * it to read 0, clear SEIS, SECS then clears) — toggling RNGEN leaves SECS set there, so one
 * transient seed error answered every later 0x27 with "no seed" until the next reset (measured on
 * an H723). The H74x/H75x RNG has no CONDRST and restarts through RNGEN. */
#if defined(STM32H723xx) || defined(STM32H725xx) || defined(STM32H730xx) || \
    defined(STM32H733xx) || defined(STM32H735xx)
#define RNG_CR_CONDRST (1u << 30)
static void sa_rng_recover(void) {
	RNG_CR_R |= RNG_CR_CONDRST;
	RNG_CR_R &= ~RNG_CR_CONDRST;
	for (uint32_t t = 0; (RNG_CR_R & RNG_CR_CONDRST) && t < 200000u; t++) {
	}
	RNG_SR_R = 0; /* SEIS/CEIS, after the restart: one raised during it is cleared with it */
	for (uint32_t t = 0; (RNG_SR_R & RNG_SR_SECS) && t < 200000u; t++) {
	}
}
#else
static void sa_rng_recover(void) {
	RNG_SR_R = 0;
	RNG_CR_R &= ~RNG_CR_RNGEN;
	RNG_CR_R |= RNG_CR_RNGEN;
}
#endif

/* sa_rng_draw fills out[0..n) from one healthy stretch of the RNG: 1 when it did, -1 when a seed
 * or clock error interrupted it (the bytes drawn are discarded with that stretch), 0 when no
 * word came in time. */
static int sa_rng_draw(uint8_t *out, int n) {
	int i = 0;
	while (i < n) {
		uint32_t t = 0;
		for (;;) {
			uint32_t sr = RNG_SR_R;
			if (sr & (RNG_SR_SECS | RNG_SR_CECS)) return -1; /* a seed or clock error stops DRDY */
			if (sr & RNG_SR_DRDY) break;
			if (++t > 200000u) return 0;
		}
		uint32_t w = RNG_DR_R;
		for (int b = 0; b < 4 && i < n; b++, i++)
			out[i] = (uint8_t)(w >> (8 * b));
	}
	return 1;
}

/* the RNG's health tests flag good noise now and then (~0.6% of seeds at the H72x/H73x reset
 * threshold, #318), so a seed error is recovered from and the seed drawn AGAIN rather than the
 * request refused: a tester never sees a transient one. Only an RNG that fails every attempt
 * refuses — then it is a real fault, never a faked seed. */
#define SA_SEED_ATTEMPTS 3

__attribute__((weak)) int diag_sa_seed(uint8_t *out, int n) {
	if (g_sa_rng <= 0) return 0;
	for (int attempt = 0; attempt < SA_SEED_ATTEMPTS; attempt++) {
		int r = sa_rng_draw(out, n);
		if (r == 1) return 1;
		if (r == 0) return 0; /* no word at all: a stalled RNG, not a health-test flag */
		sa_rng_recover();
	}
	return 0;
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

/* The KEEP cell: what the diagnostic server must carry across its own reset — the 0x27 state
 * (uds.kept_len bytes: each level's failed-key count and whether a lockout is running), or a
 * reset between guesses, or during a lockout, would buy fresh attempts. In D3 SRAM4, which a
 * system reset does not clear: just below the boot cells (bootmap.h, 0x38000FE0+) and clear of
 * xcore's map (which ends well below 0x38000F00). Garbage after power-on, so a magic and a check
 * word guard it, and it is consumed when read. Not across a power cycle: that is the journal's
 * (docs/diagnostics.md R6). */
#ifndef DIAG_KEEP_ADDR
#define DIAG_KEEP_ADDR 0x38000FC0u
#endif
#define DIAG_KEEP_MAGIC 0x504B4744u /* 'DGKP' */
#define DIAG_KEEP_WORDS 3             /* up to 12 bytes; with magic and check 0x38000FC0..0x38000FD3 */

void diag_keep_save(const uint8_t *kept, int n) {
	volatile uint32_t *c = (volatile uint32_t *)DIAG_KEEP_ADDR;
	uint32_t w[DIAG_KEEP_WORDS] = {0, 0, 0};
	for (int i = 0; i < n && i < 4 * DIAG_KEEP_WORDS; i++)
		w[i / 4] |= (uint32_t)kept[i] << (8 * (i % 4));
	uint32_t check = ~0u;
	for (int j = 0; j < DIAG_KEEP_WORDS; j++) {
		c[1 + j] = w[j];
		check ^= w[j];
	}
	c[1 + DIAG_KEEP_WORDS] = check;
	c[0] = DIAG_KEEP_MAGIC;
}

/* 1 and the bytes when the cell holds what diag_keep_save wrote before this reset; 0 otherwise
 * (a power-on, or no reset by the server). Consumed either way. */
int diag_keep_load(uint8_t *kept, int n) {
	volatile uint32_t *c = (volatile uint32_t *)DIAG_KEEP_ADDR;
	uint32_t w[DIAG_KEEP_WORDS];
	uint32_t check = ~0u;
	for (int j = 0; j < DIAG_KEEP_WORDS; j++) {
		w[j] = c[1 + j];
		check ^= w[j];
	}
	int ok = c[0] == DIAG_KEEP_MAGIC && c[1 + DIAG_KEEP_WORDS] == check;
	c[0] = 0;
	if (!ok) return 0;
	for (int i = 0; i < n && i < 4 * DIAG_KEEP_WORDS; i++)
		kept[i] = (uint8_t)((w[i / 4] >> (8 * (i % 4))) & 0xFFu);
	return 1;
}
