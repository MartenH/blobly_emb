/* diag_sa.c — the SecurityAccess (0x27) seam of a node's diagnostic server on the target
 * (docs/diagnostics.md, decision D5). comm/uds carries no key: the generated comm thread asks
 * these two functions for a seed and a verdict. Both are WEAK — an OEM algorithm, or an HSM,
 * replaces them in the node's own glue; the defaults are the bench's.
 *
 *   diag_sa_seed   — `n` random bytes from the STM32H7 true RNG (HSI48 kernel clock). Bounded
 *                    polling, so a dead RNG answers "no seed" (the server then answers
 *                    conditionsNotCorrect) instead of hanging the comm thread.
 *   diag_sa_key_ok — the REFERENCE key, key[i] = seed[i] ^ 0xFF: the algorithm blobly_net's
 *                    client and the host bridge use, so the bench unlocks with ONE algorithm. Not
 *                    a secret; compared in constant time all the same, as a real one must be. */
#include <stdint.h>

#define RCC_CR_R       (*(volatile uint32_t *)0x58024400u)
#define RCC_D2CCIP2R_R (*(volatile uint32_t *)0x58024454u)
#define RCC_AHB2ENR_R  (*(volatile uint32_t *)0x580244DCu)
#define RNG_CR_R       (*(volatile uint32_t *)0x48021800u)
#define RNG_SR_R       (*(volatile uint32_t *)0x48021804u)
#define RNG_DR_R       (*(volatile uint32_t *)0x48021808u)

static int g_sa_rng_ready = 0;

static int sa_rng_setup(void) {
	RCC_CR_R |= (1u << 12); /* HSI48ON */
	for (uint32_t t = 0; !(RCC_CR_R & (1u << 13)); t++)
		if (t > 2000000u) return 0; /* HSI48RDY never came */
	RCC_D2CCIP2R_R &= ~(3u << 8); /* RNGSEL = 00 = HSI48 */
	RCC_AHB2ENR_R |= (1u << 6);    /* RNG kernel+bus clock */
	(void)RCC_AHB2ENR_R;
	RNG_CR_R = (1u << 2); /* RNGEN, clock-error detection on */
	g_sa_rng_ready = 1;
	return 1;
}

__attribute__((weak)) int diag_sa_seed(uint8_t *out, int n) {
	if (!g_sa_rng_ready && !sa_rng_setup()) return 0;
	int i = 0;
	while (i < n) {
		uint32_t t = 0;
		while (!(RNG_SR_R & 1u)) { /* DRDY */
			if (++t > 200000u) return 0;
		}
		if (RNG_SR_R & 0x6u) { /* seed/clock error */
			RNG_SR_R = 0;
			return 0;
		}
		uint32_t w = RNG_DR_R;
		for (int b = 0; b < 4 && i < n; b++, i++)
			out[i] = (uint8_t)(w >> (8 * b));
	}
	return 1;
}

__attribute__((weak)) int diag_sa_key_ok(uint8_t level, const uint8_t *seed, const uint8_t *key, int n) {
	(void)level;
	uint8_t diff = 0;
	for (int i = 0; i < n; i++)
		diff |= (uint8_t)(key[i] ^ (uint8_t)(seed[i] ^ 0xFFu));
	return diff == 0;
}
