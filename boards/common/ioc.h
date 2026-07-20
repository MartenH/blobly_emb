/* Wait-free triple-buffer IOC for cross-THREAD signals — the ONE copy every target
 * example compiles against (it is a platform CONTRACT: generated V code and each
 * example's glue C share the handoff protocol, so per-example copies could only
 * drift into an ABI bug).
 *
 * A single-producer / single-consumer "latest value wins" channel: the writer always has
 * a private buffer to fill and the reader always gets the most recent COMPLETE value —
 * neither ever blocks, spins, or tears a value (the blobly IOC invariant, ioc-perf memory).
 * Three buffers + one atomically-exchanged index byte (2 index bits + a fresh flag) hand
 * ownership over without a lock. The writer and reader are two ThreadX threads on ONE
 * core (a context switch can land mid-operation, so the exchange must be atomic).
 * CROSS-CORE this exchange is NOT sound: LDREX/STREX between the H755's cores does not
 * arbitrate (162/200k torn reads measured 2026-07-12) — cross-core signals use
 * boards/common/xioc.h (plain-store seq-stamped slots) instead.
 *
 * Arenas are SIZE-PROPORTIONAL: each channel carries 3 x the SIGNAL's byte size (caller-
 * owned arena, sized at the call site where the signal type is known), never 3 x the
 * ceiling — copies and RAM stay proportional to the signal. IOC_MAX is the loud upper
 * bound (the host slot bound, osal_native.c, and the eth PDU bound, comm.com max_pdu);
 * anything bigger is not signal state and rides an owner-buffer path (trace ring,
 * ISO-TP link), never an IOC cell.
 */
#ifndef BLOBLY_IOC_H
#define BLOBLY_IOC_H

#include <stdint.h>

/* The IOC payload ceiling. The validator rejects wider signals at build time; this
 * bound exists so glue arenas have a named limit, not so channels allocate it. */
#define IOC_MAX 64

/* The SCALAR wrapper shape (two u32s) the existing glue pools expose to generated
 * code (ioc_pub/ioc_get by index); struct-bearing channels use the byte API. */
typedef struct {
	uint32_t a;
	uint32_t b;
} sig_t;

#define IOC_FRESH 0x04u /* bit2 of `shared`: the middle buffer holds an unread value */

typedef struct __attribute__((aligned(32))) {
	volatile uint8_t *arena; /* caller-owned, 3 * size bytes */
	uint16_t size;           /* one signal's byte size (<= IOC_MAX) */
	volatile unsigned char shared; /* bits0-1: index of the latest published slot; bit2: fresh */
	unsigned char wr;              /* writer's private slot (writer-only) */
	unsigned char rd;              /* reader's private slot (reader-only) */
} ioc_t;

/* Volatile byte copy: the payload is copied element-by-element through volatile
 * pointers (never a plain aggregate assignment) so the compiler cannot cache or
 * reorder a payload access relative to the atomic index publish — the invariant
 * that keeps the protocol correct beyond the coherent single-core case. */
static inline void ioc_vcopy(volatile uint8_t *dst, const volatile uint8_t *src, uint16_t n)
{
	for (uint16_t i = 0; i < n; i++)
		dst[i] = src[i];
}

/* Init to three distinct zeroed slots so writer, reader, and the shared middle never
 * alias. The arena must hold 3 * size bytes and belongs to this channel alone. */
static inline void ioc_init(ioc_t *b, volatile uint8_t *arena, uint16_t size)
{
	b->arena = arena;
	b->size = size;
	for (uint32_t i = 0; i < 3u * (uint32_t)size; i++)
		arena[i] = 0u;
	b->shared = 0u; /* slot 0 is the middle, not fresh */
	b->wr = 1u;
	b->rd = 2u;
}

/* Publish the value at `v` (size bytes) as the latest. Fill the private back buffer
 * (volatile copy), then atomically swap it into `shared` (marking it fresh) and take
 * whatever slot was there as the new back. The ACQ_REL exchange orders the payload
 * store before the index publish. */
static inline void ioc_write_bytes(ioc_t *b, const void *v)
{
	ioc_vcopy(b->arena + (uint32_t)b->wr * b->size, (const volatile uint8_t *)v, b->size);
	unsigned char prev = __atomic_exchange_n(&b->shared, (unsigned char)(b->wr | IOC_FRESH),
	                                         __ATOMIC_ACQ_REL);
	b->wr = prev & 0x03u;
}

/* Read the most recent complete value into `out` (size bytes). If a fresh value has
 * been published, atomically swap our front buffer for the middle (clearing fresh);
 * otherwise re-read the last one — either way it never blocks and never sees a
 * half-written value. The ACQUIRE load orders the payload read after the index. */
static inline void ioc_read_bytes(ioc_t *b, void *out)
{
	if (__atomic_load_n(&b->shared, __ATOMIC_ACQUIRE) & IOC_FRESH) {
		unsigned char prev = __atomic_exchange_n(&b->shared, b->rd, __ATOMIC_ACQ_REL);
		b->rd = prev & 0x03u;
	}
	ioc_vcopy((volatile uint8_t *)out, b->arena + (uint32_t)b->rd * b->size, b->size);
}

/* ioc_read_bytes_ever: ioc_read_bytes plus a race-free ever-published report
 * (REQ-IO-009). *ever latches from the SAME atomic exchange that consumes the fresh
 * flag — a separate pre-read freshness check can lose the only sample of a short
 * pulse (publisher lands between the check and the read; the read consumes it while
 * the caller still believes "never published"). Only the reader clears FRESH, so
 * exchange-path-taken == a value was truly published. *ever is monotonic only if
 * the caller latches it (see ioc_get_ever in the example glue). */
static inline void ioc_read_bytes_ever(ioc_t *b, void *out, int *ever)
{
	*ever = 0;
	if (__atomic_load_n(&b->shared, __ATOMIC_ACQUIRE) & IOC_FRESH) {
		unsigned char prev = __atomic_exchange_n(&b->shared, b->rd, __ATOMIC_ACQ_REL);
		b->rd = prev & 0x03u;
		if (prev & IOC_FRESH)
			*ever = 1;
	}
	ioc_vcopy((volatile uint8_t *)out, b->arena + (uint32_t)b->rd * b->size, b->size);
}

/* --- the scalar convenience layer: the existing pools' sig_t shape ------------- */

static inline void ioc_write(ioc_t *b, sig_t v)
{
	ioc_write_bytes(b, &v);
}

static inline sig_t ioc_read(ioc_t *b)
{
	sig_t r;
	ioc_read_bytes(b, &r);
	return r;
}

static inline sig_t ioc_read_ever(ioc_t *b, int *ever)
{
	sig_t r;
	ioc_read_bytes_ever(b, &r, ever);
	return r;
}

#endif
