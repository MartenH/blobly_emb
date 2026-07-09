/* P3c-1 Phase 5 — wait-free triple-buffer IOC for cross-thread (cross-core-ready) signals.
 *
 * A single-producer / single-consumer "latest value wins" channel: the writer always has
 * a private buffer to fill and the reader always gets the most recent COMPLETE value —
 * neither ever blocks, spins, or tears a value (the blobly IOC invariant, ioc-perf memory).
 * Three buffers + one atomically-exchanged index byte (2 index bits + a fresh flag) hand
 * ownership over without a lock. On the single-core H735 the writer and reader are two
 * ThreadX threads (a context switch can land mid-operation, so the exchange must be
 * atomic); the SAME code carries a signal across cores when the buffers live in shared
 * SRAM — which is what Phase 6's generated cross-core IOC will do.
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

typedef struct {
	sig_t slot[3];
	volatile unsigned char shared; /* bits0-1: index of the latest published slot; bit2: fresh */
	unsigned char wr;              /* writer's private slot (writer-only) */
	unsigned char rd;              /* reader's private slot (reader-only) */
} ioc_t;

/* Init to three distinct slots so writer, reader, and the shared middle never alias. */
static inline void ioc_init(ioc_t *b)
{
	b->slot[0] = (sig_t){ 0, 0 };
	b->slot[1] = (sig_t){ 0, 0 };
	b->slot[2] = (sig_t){ 0, 0 };
	b->shared = 0u; /* slot 0 is the middle, not fresh */
	b->wr = 1u;
	b->rd = 2u;
}

/* Publish `v` as the latest value. Fill the private back buffer, then atomically swap it
 * into `shared` (marking it fresh) and take whatever slot was there as the new back. */
static inline void ioc_write(ioc_t *b, sig_t v)
{
	b->slot[b->wr] = v;
	unsigned char prev = __atomic_exchange_n(&b->shared, (unsigned char)(b->wr | IOC_FRESH),
	                                         __ATOMIC_ACQ_REL);
	b->wr = prev & 0x03u;
}

/* Read the most recent complete value. If a fresh value has been published, atomically
 * swap our front buffer for the middle (clearing fresh); otherwise re-read the last one —
 * either way it never blocks and never sees a half-written value. */
static inline sig_t ioc_read(ioc_t *b)
{
	if (__atomic_load_n(&b->shared, __ATOMIC_ACQUIRE) & IOC_FRESH) {
		unsigned char prev = __atomic_exchange_n(&b->shared, b->rd, __ATOMIC_ACQ_REL);
		b->rd = prev & 0x03u;
	}
	return b->slot[b->rd];
}

#endif
