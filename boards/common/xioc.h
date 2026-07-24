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

/* The ordering barrier. On Arm this is DMB (the scheme's original home); anywhere else —
 * the host build, where this header is CI-tested — a seq-cst fence. One seam, so the same
 * plain-store discipline is compiled and TESTED on both. */
#if defined(__arm__) || defined(__ARM_ARCH)
#define XIOC_DMB() __asm__ volatile("dmb" ::: "memory")
/* On Arm the plain volatile 32-bit access IS the mechanism (single-copy atomic). */
#define XIOC_LD(p) (*(p))
#define XIOC_ST(p, v) (*(p) = (v))
#else
#define XIOC_DMB() __atomic_thread_fence(__ATOMIC_SEQ_CST)
/* Off-Arm (the host tear test): a fence orders but does not de-race the accesses — plain
 * concurrent loads/stores are formally UB in C. Relaxed atomics compile to the same MOVs
 * on x86 and make the host result stand on defined behavior (codex #201). */
#define XIOC_LD(p) __atomic_load_n((p), __ATOMIC_RELAXED)
#define XIOC_ST(p, v) __atomic_store_n((p), (v), __ATOMIC_RELAXED)
#endif

#define XIOC_SLOTS 4u

/* The WIDE channel (2026-07-23): size-proportional slots up to one PDU (IOC_MAX = 64 B =
 * XIOC_MAX_WORDS u32s). Exists because the fixed {a,b} cell broke location transparency:
 * a 40 B signal that is legal between threads on one core became illegal the moment its
 * producer moved cores — moving a partition must change COST, never the communication
 * contract. Same discipline as the pair cell: plain 32-bit stores, seq invalidate ->
 * payload -> validate -> publish, no exclusives (the cores do not arbitrate LDREX/STREX —
 * 162/200k torn reads measured 2026-07-12). The lap argument SCALES with the width: the
 * reader's copy window grows to <=16 loads, but a lap now requires XIOC_SLOTS-1 publishes
 * of the SAME width (16 stores + 3 barriers each) — the implausibility ratio is preserved,
 * and the seq recheck still DETECTS the impossible case rather than assuming it. */
#define XIOC_MAX_WORDS 16u /* = IOC_MAX / 4: a signal wider than one PDU is bulk, not a signal */

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
	XIOC_ST(&s->seq, 0u); /* invalidate: a reader copying now will fail its recheck */
	XIOC_DMB();
	XIOC_ST(&s->a, a);
	XIOC_ST(&s->b, b);
	XIOC_DMB();
	XIOC_ST(&s->seq, n); /* validate */
	XIOC_DMB();
	XIOC_ST(&c->latest, n); /* publish */
}

/* Returns 1 if rd holds a NEWER value than before the call, 0 otherwise (rd always
 * holds the best-known value either way). Straight-line: never loops. */
static inline int xioc_read(const xioc_t *c, xioc_rd_t *rd)
{
	uint32_t n = XIOC_LD(&c->latest);
	if (n == 0u || n == rd->seq) {
		return 0; /* nothing published yet, or nothing new */
	}
	const xioc_slot_t *s = &c->slot[n % XIOC_SLOTS];
	uint32_t a = XIOC_LD(&s->a);
	uint32_t b = XIOC_LD(&s->b);
	XIOC_DMB();
	if (XIOC_LD(&s->seq) != n) {
		return 0; /* impossible-lap detected: keep the cached last-good value */
	}
	rd->seq = n;
	rd->a = a;
	rd->b = b;
	return 1;
}

/* ---- the wide channel ------------------------------------------------------------------
 * Layout: one header + XIOC_SLOTS slots, each slot = 1 seq word + `words` payload words,
 * contiguous in the shared window. The generator (or glue) reserves
 * XIOC_N_BYTES(words) per channel and both sides agree on `words` at build time.
 */
typedef struct __attribute__((aligned(32))) {
	volatile uint32_t latest; /* last fully published seq; 0 = nothing yet */
	uint32_t wseq;            /* WRITER-private publish counter */
	uint32_t words;           /* payload words per slot (channel geometry, set once) */
	uint32_t pad[5];
	volatile uint32_t cell[]; /* XIOC_SLOTS x (1 seq + words payload) */
} xioc_n_t;

/* Rounded UP to the 32 B line: channels are packed consecutively, and an unrounded stride
 * (e.g. words=10 -> 208 B) would misalign every following xioc_n_t — undefined behavior on
 * the typed access and a violation of the no-shared-cache-line invariant (codex #201). */
#define XIOC_N_BYTES(words) \
	(((uint32_t)sizeof(xioc_n_t) + 4u * XIOC_SLOTS * (1u + (words)) + 31u) & ~31u)

static inline volatile uint32_t *xioc_n_slot(xioc_n_t *c, uint32_t n)
{
	return &c->cell[(n % XIOC_SLOTS) * (1u + c->words)];
}

static inline void xioc_n_init(xioc_n_t *c, uint32_t words)
{
	c->words = words;
	c->latest = 0u;
	c->wseq = 0u;
	for (uint32_t i = 0; i < XIOC_SLOTS * (1u + words); i++) {
		c->cell[i] = 0u;
	}
}

static inline void xioc_n_write(xioc_n_t *c, const uint32_t *src)
{
	uint32_t n = ++c->wseq;
	if (n == 0u) { /* 2^32 publishes: skip 0, it means "empty/being written" */
		n = ++c->wseq;
	}
	volatile uint32_t *s = xioc_n_slot(c, n);
	XIOC_ST(&s[0], 0u); /* invalidate: a reader copying now fails its recheck */
	XIOC_DMB();
	for (uint32_t i = 0; i < c->words; i++) {
		XIOC_ST(&s[1u + i], src[i]);
	}
	XIOC_DMB();
	XIOC_ST(&s[0], n); /* validate */
	XIOC_DMB();
	XIOC_ST(&c->latest, n); /* publish */
}

/* Reader: `dst` is the reader-private last-good buffer (>= words u32s, reused across
 * calls); `rd_seq` its seq. Returns 1 when dst now holds a NEWER complete value, 0
 * otherwise — and on 0, dst is UNTOUCHED (the copy is staged through a stack temp and
 * committed only after the recheck), so the reader always holds a complete value.
 * Straight-line, bounded: never loops, never spins. */
static inline int xioc_n_read(xioc_n_t *c, uint32_t *rd_seq, uint32_t *dst)
{
	uint32_t n = XIOC_LD(&c->latest);
	if (n == 0u || n == *rd_seq) {
		return 0; /* nothing published yet, or nothing new */
	}
	volatile uint32_t *s = xioc_n_slot(c, n);
	uint32_t tmp[XIOC_MAX_WORDS];
	uint32_t w = c->words;
	for (uint32_t i = 0; i < w; i++) {
		tmp[i] = XIOC_LD(&s[1u + i]);
	}
	XIOC_DMB();
	if (XIOC_LD(&s[0]) != n) {
		return 0; /* impossible-lap detected: keep the cached last-good value */
	}
	for (uint32_t i = 0; i < w; i++) {
		dst[i] = tmp[i];
	}
	*rd_seq = n;
	return 1;
}

#endif
