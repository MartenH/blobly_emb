/* cyc_clock.h — the core's 32-bit cycle counter (DWT->CYCCNT) extended to 64 bits, with a
 * microsecond clock carried beside it.
 *
 * The 64-bit count is the unit the core-load accounting adds up (trace_hooks.c): whole cycles, so
 * a share is exact however short the slices are. The microsecond clock stamps the trace records:
 * floor(cycles / mhz), the value a 64-bit division gives, kept by carrying the remainder forward —
 * one 32-bit divide (the core's UDIV) per advance, where a 64-bit division is a libgcc call. The
 * hooks advance the clock on every ISR and thread switch, so that difference is paid thousands of
 * times a second. Pure C, so the host test includes it (tools/cyc_clock/cyc_clock_test.v); the
 * caller serialises the advances. */
#ifndef BLOBLY_CYC_CLOCK_H
#define BLOBLY_CYC_CLOCK_H
#include <stdint.h>

/* tagged: V3 declares a V `struct C.cyc_clock_t` as `typedef struct cyc_clock_t cyc_clock_t;` */
typedef struct cyc_clock_t {
	uint32_t last; /* the counter at the last advance */
	uint32_t us;   /* floor(cyc / mhz), modulo 2^32 */
	uint32_t rem;  /* cyc - us * mhz, below mhz */
	uint64_t cyc;  /* cycles counted since the counter read 0 */
} cyc_clock_t;

/* cyc_clock_advance: move the clock to counter value `now`. The counter must move less than 2^32
 * cycles between two advances (about 10 s at 400 MHz). */
static inline void cyc_clock_advance(cyc_clock_t *c, uint32_t now, uint32_t mhz)
{
	uint32_t d = now - c->last; /* modular: the counter wraps */
	c->last = now;
	c->cyc += d;
	uint32_t q = d / mhz;
	uint32_t r = c->rem + (d - q * mhz); /* below 2 * mhz */
	if (r >= mhz) {
		r -= mhz;
		q++;
	}
	c->rem = r;
	c->us += q;
}

#endif
