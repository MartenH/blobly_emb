/* xioc — the CROSS-CORE flavor of the wait-free SPSC "latest value wins" signal channel.
 *
 * Why ioc.h's triple buffer is NOT enough across cores (measured, 2026-07-12, H755
 * CM4 writer vs CM7 reader on D3 SRAM4): its handoff is an atomic exchange, i.e.
 * LDREXB/STREXB — and the two cores' exclusive monitors do not arbitrate against each
 * other on this fabric, so the writer's and reader's exchanges can both "succeed" on
 * stale state and alias a slot: 162 torn reads in 200k under a max-rate writer (the
 * iocx stress harness). ioc.h remains correct WITHIN one core (its original use).
 *
 * This scheme keeps the same contract — single producer, single consumer, wait-free on
 * BOTH sides, reader always gets a complete recent value — using only plain 32-bit
 * stores/loads (single-copy atomic on ARMv7-M) and DMB barriers. No read-modify-write
 * crosses the core boundary, so no monitor arbitration is needed at all.
 *
 *   writer, per publish (seq n, slot n % XIOC_SLOTS):
 *     slot.seq = 0        (invalidate)      DMB
 *     slot.a/b = payload                    DMB
 *     slot.seq = n        (validate)        DMB
 *     latest = n          (publish)
 *
 *   reader, per poll:
 *     n = latest; copy slot[n % XIOC_SLOTS]; DMB; recheck slot.seq == n
 *       match    -> consistent value: cache + return it
 *       mismatch -> the writer lapped the WHOLE ring during our 2-word copy (it must
 *                   complete XIOC_SLOTS-1 full publishes, >= ~100 cycles of stores and
 *                   barriers, inside a ~15-cycle window — physically implausible, but
 *                   DETECTED, never assumed): return the cached last-good value.
 *
 * Both sides are straight-line code — no loop, no retry, no spin: wait-free by
 * construction, degrading (only in the impossible-lap case) to a value one publish
 * older. Requires the buffers to live in UNCACHED shared memory (the D-cache-off
 * policy, or an MPU non-cacheable region) — same rule as every shared-SRAM structure.
 */
#ifndef BLOBLY_XIOC_H
#define BLOBLY_XIOC_H

#include <stdint.h>

#define XIOC_SLOTS 4u

typedef struct {
	volatile uint32_t seq; /* 0 = being written; else the publish counter that filled it */
	volatile uint32_t a;
	volatile uint32_t b;
	uint32_t pad; /* 16 B per slot: a/b never straddle what a lap can half-fill */
} xioc_slot_t;

/* One channel, cache-line aligned/padded so neighbouring channels never share a line. */
typedef struct __attribute__((aligned(32))) {
	xioc_slot_t slot[XIOC_SLOTS];
	volatile uint32_t latest; /* last fully published seq; 0 = nothing published yet */
	uint32_t wseq;            /* WRITER-private publish counter (reader never reads it) */
	uint32_t pad[6];
} xioc_t;

/* Reader-side state — lives on the READER (private memory), not in the shared cell:
 * the last consistent value and its seq (freshness = seq advanced since last read). */
typedef struct {
	uint32_t seq;
	uint32_t a;
	uint32_t b;
} xioc_rd_t;

static inline void xioc_init(xioc_t *c)
{
	for (uint32_t i = 0; i < XIOC_SLOTS; i++) {
		c->slot[i].seq = 0u;
		c->slot[i].a = 0u;
		c->slot[i].b = 0u;
	}
	c->latest = 0u;
	c->wseq = 0u;
}

static inline void xioc_write(xioc_t *c, uint32_t a, uint32_t b)
{
	uint32_t n = ++c->wseq;
	if (n == 0u) { /* 2^32 publishes: skip 0, it means "empty/being written" */
		n = ++c->wseq;
	}
	xioc_slot_t *s = &c->slot[n % XIOC_SLOTS];
	s->seq = 0u; /* invalidate: a reader copying now will fail its recheck */
	__asm__ volatile("dmb" ::: "memory");
	s->a = a;
	s->b = b;
	__asm__ volatile("dmb" ::: "memory");
	s->seq = n; /* validate */
	__asm__ volatile("dmb" ::: "memory");
	c->latest = n; /* publish */
}

/* Returns 1 if rd holds a NEWER value than before the call, 0 otherwise (rd always
 * holds the best-known value either way). Straight-line: never loops. */
static inline int xioc_read(const xioc_t *c, xioc_rd_t *rd)
{
	uint32_t n = c->latest;
	if (n == 0u || n == rd->seq) {
		return 0; /* nothing published yet, or nothing new */
	}
	const xioc_slot_t *s = &c->slot[n % XIOC_SLOTS];
	uint32_t a = s->a;
	uint32_t b = s->b;
	__asm__ volatile("dmb" ::: "memory");
	if (s->seq != n) {
		return 0; /* impossible-lap detected: keep the cached last-good value */
	}
	rd->seq = n;
	rd->a = a;
	rd->b = b;
	return 1;
}

#endif
