/* diag_sa.c — the SecurityAccess (0x27) seam of a node's diagnostic server on the target
 * (docs/diagnostics.md, decision D5). comm/uds carries no key: the generated comm thread asks the
 * board for a seed, and the OEM's glue for a verdict.
 *
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
