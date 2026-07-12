/* P3c-1 Phase 5 — wait-free triple-buffer IOC for cross-thread (cross-core-ready) signals.
 *
 * A single-producer / single-consumer "latest value wins" channel: the writer always has
 * a private buffer to fill and the reader always gets the most recent COMPLETE value —
 * neither ever blocks, spins, or tears a value (the blobly IOC invariant, ioc-perf memory).
 * Three buffers + one atomically-exchanged index byte (2 index bits + a fresh flag) hand
 * ownership over without a lock. On the single-core H735 the writer and reader are two
 * ThreadX threads (a context switch can land mid-operation, so the exchange must be
 * atomic). CROSS-CORE this exchange is NOT sound: LDREX/STREX between the H755's cores
 * does not arbitrate (162/200k torn reads measured 2026-07-12) — cross-core signals use
 * boards/common/xioc.h (plain-store seq-stamped slots) instead.
 */
#ifndef BLOBLY_THREADX_H735_IOC_H
#define BLOBLY_THREADX_H735_IOC_H

#include <stdint.h>

/* One signal payload. Two u32s cover this demo's signals: LoadCmd carries {iters},
 * Workload carries {iters_seen, acc}. */
typedef struct {
	uint32_t a;
	uint32_t b;
} sig_t;

#define IOC_FRESH 0x04u /* bit2 of `shared`: the middle buffer holds an unread value */

/* The payload buffers are volatile and copied field-by-field (never a plain aggregate
 * assignment) so the compiler cannot cache or reorder a non-scalar payload access relative
 * to the atomic index publish — the blobly IOC invariant that keeps the cross-core
 * (non-coherent shared SRAM) case correct, not just the coherent single-core demo. */
static inline void sig_vcopy(volatile sig_t *dst, const volatile sig_t *src)
{
	dst->a = src->a;
	dst->b = src->b;
}

/* Cache-line aligned (Cortex-M7 line = 32 B) and padded to a full line, so independent
 * channels (e.g. g_loadcmd and g_workload) never share a cache line — no false sharing
 * when the buffers live in shared SRAM (the documented no-false-sharing IOC invariant). */
typedef struct __attribute__((aligned(32))) {
	volatile sig_t slot[3];
	volatile unsigned char shared; /* bits0-1: index of the latest published slot; bit2: fresh */
	unsigned char wr;              /* writer's private slot (writer-only) */
	unsigned char rd;              /* reader's private slot (reader-only) */
} ioc_t;

/* Init to three distinct slots so writer, reader, and the shared middle never alias. */
static inline void ioc_init(ioc_t *b)
{
	for (int i = 0; i < 3; i++) {
		b->slot[i].a = 0u;
		b->slot[i].b = 0u;
	}
	b->shared = 0u; /* slot 0 is the middle, not fresh */
	b->wr = 1u;
	b->rd = 2u;
}

/* Publish `v` as the latest value. Fill the private back buffer (volatile copy), then
 * atomically swap it into `shared` (marking it fresh) and take whatever slot was there as
 * the new back. The ACQ_REL exchange orders the payload store before the index publish. */
static inline void ioc_write(ioc_t *b, sig_t v)
{
	sig_vcopy(&b->slot[b->wr], &v);
	unsigned char prev = __atomic_exchange_n(&b->shared, (unsigned char)(b->wr | IOC_FRESH),
	                                         __ATOMIC_ACQ_REL);
	b->wr = prev & 0x03u;
}

/* Read the most recent complete value. If a fresh value has been published, atomically
 * swap our front buffer for the middle (clearing fresh); otherwise re-read the last one —
 * either way it never blocks and never sees a half-written value. The ACQUIRE load orders
 * the payload read after observing the fresh index. */
static inline sig_t ioc_read(ioc_t *b)
{
	if (__atomic_load_n(&b->shared, __ATOMIC_ACQUIRE) & IOC_FRESH) {
		unsigned char prev = __atomic_exchange_n(&b->shared, b->rd, __ATOMIC_ACQ_REL);
		b->rd = prev & 0x03u;
	}
	sig_t r;
	sig_vcopy((volatile sig_t *)&r, &b->slot[b->rd]);
	return r;
}

#endif
