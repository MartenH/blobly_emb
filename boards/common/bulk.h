/* bulk — the portable pool + descriptor-ring transport for payloads that must arrive
 * WHOLE (docs/bulk-transport.md). Signals are latest-value-wins and ride ioc/xioc; bulk
 * is the other species: a log window, a measurement block, an object. The payload never
 * moves through a channel — a REFERENCE does:
 *
 *   producer:  bulk_loan()    -> a free buffer index (FAILS when the pool is empty —
 *                                the producer decides drop-newest / count, REQ-BULK-002)
 *              fill           -> write the payload IN PLACE via bulk_buf()
 *              bulk_publish() -> ownership moves to the consumer (descriptor ring)
 *   consumer:  bulk_take()    -> the OLDEST published buffer index, by reference
 *              read           -> same bytes, same address — zero copies end to end
 *              bulk_release() -> the buffer returns to the pool
 *
 * Ownership rules, stated once: a producer either PUBLISHES a loaned buffer or keeps it
 * for a future fill — it never returns one to the pool itself (bulk_release writes the
 * consumer-owned free-ring cursor; a producer calling it would put two writers on one
 * SPSC field). Release is the consumer's half, for buffers it took.
 *
 * Two SPSC rings carry buffer indices, each with exactly one writing side per field
 * (REQ-BULK-003, the xioc lesson generalized): the READY ring (producer writes head,
 * consumer writes tail) and the FREE ring (consumer writes head, producer writes tail).
 * Plain aligned volatile 32-bit stores + barriers only — no LDREX/STREX anywhere, so
 * the scheme is sound between sides whose exclusive monitors do not arbitrate (H755
 * cores, a DMA engine, two processes over mmap). On Arm the volatile access IS the
 * mechanism (single-copy atomic; the compiler may never cache a cross-side cursor in a
 * poll loop); off-Arm the seams compile to relaxed atomics. Ring capacity equals the
 * pool size: with N buffers at most N descriptors are ever in flight per ring, so a
 * slot is always consumed before it can be rewritten — bounded by construction.
 *
 * The region must be memory both sides address identically and coherently (uncached
 * shared SRAM on target — same policy as xioc; MAP_SHARED memory on the host), and
 * 32-byte aligned (bulk_t is declared aligned(32); an underaligned byte arena is UB —
 * align the backing storage or round the base up). The doorbell and cache hooks of the
 * survey are deliberately NOT here: the ring state is the only truth, polling is the
 * P1 baseline, and a board seam can add notify later without touching this contract.
 *
 * Layout inside one region (BULK_BYTES(nbuf, bufsz) bytes, bufsz a multiple of 32):
 *   bulk_t header (3 cache lines, cursors split by OWNER — see below) | free ring:
 *   nbuf u32 | ready ring: nbuf u32 | len: nbuf u32 | pad to 32 | nbuf * bufsz buffers
 */
#ifndef BLOBLY_BULK_H
#define BLOBLY_BULK_H

#include <stdint.h>
#include "xioc.h" /* the XIOC_DMB / XIOC_LD / XIOC_ST seams: Arm = plain volatile + DMB,
                   * host = relaxed atomics + fence — one discipline, compiled + tested
                   * on both (REQ-BULK-003) */

#define BULK_MAGIC 0x424C4B31u /* "BLK1" — geometry initialized and visible */

/* The header is three 32 B lines so the two sides never write the same line (false
 * sharing on a coherent host; and a future cached port can clean/invalidate one side's
 * cursors without touching the other's — codex #213):
 *   line 0: geometry — written once by init, read-only after the magic handshake
 *   line 1: PRODUCER-owned cursors (r_head, f_tail, overflows)
 *   line 2: CONSUMER-owned cursors (r_tail, f_head)
 * Cross-side fields are volatile: on Arm the seams are plain accesses, and a non-
 * volatile cursor could be cached across a service loop's polls (codex #213). */
typedef struct __attribute__((aligned(32))) {
	volatile uint32_t magic; /* BULK_MAGIC once geometry + free ring are visible */
	uint32_t nbuf;           /* buffers in the pool (= each ring's capacity) */
	uint32_t bufsz;          /* bytes per buffer, multiple of 32 */
	uint32_t pad0[5];
	volatile uint32_t r_head;    /* ready ring: producer writes */
	volatile uint32_t f_tail;    /* free ring: producer writes (loan) */
	volatile uint32_t overflows; /* producer-owned: failed loans — loss is counted,
	                              * never silent (REQ-BULK-002) */
	uint32_t pad1[5];
	volatile uint32_t r_tail; /* ready ring: consumer writes */
	volatile uint32_t f_head; /* free ring: consumer writes (release); init pre-fills */
	uint32_t pad2[6];
} bulk_t;

#define BULK_HDR_BYTES ((uint32_t)sizeof(bulk_t)) /* 96: three aligned lines */
/* header | 3 index arrays (free, ready, len) rounded to the 32 B line | buffers */
#define BULK_BYTES(nbuf, bufsz) \
	(BULK_HDR_BYTES + (((3u * 4u * (nbuf)) + 31u) & ~31u) + (nbuf) * (bufsz))

static inline volatile uint32_t *bulk_free_ring(bulk_t *b)
{
	return (volatile uint32_t *)((uint8_t *)b + BULK_HDR_BYTES);
}
static inline volatile uint32_t *bulk_ready_ring(bulk_t *b)
{
	return bulk_free_ring(b) + b->nbuf;
}
static inline volatile uint32_t *bulk_len_arr(bulk_t *b)
{
	return bulk_free_ring(b) + 2u * b->nbuf;
}
static inline uint8_t *bulk_buf(bulk_t *b, uint32_t idx)
{
	uint32_t arrs = ((3u * 4u * b->nbuf) + 31u) & ~31u;
	return (uint8_t *)b + BULK_HDR_BYTES + arrs + idx * b->bufsz;
}

/* bulk_init — ONE side (whoever owns the window's bring-up) initializes; the other side
 * polls bulk_valid() before first use. Every buffer starts in the free ring. */
static inline void bulk_init(bulk_t *b, uint32_t nbuf, uint32_t bufsz)
{
	XIOC_ST(&b->magic, 0u);
	XIOC_DMB();
	b->nbuf = nbuf;
	b->bufsz = bufsz;
	XIOC_ST(&b->overflows, 0u);
	XIOC_ST(&b->r_head, 0u);
	XIOC_ST(&b->r_tail, 0u);
	XIOC_ST(&b->f_tail, 0u);
	volatile uint32_t *fr = bulk_free_ring(b);
	for (uint32_t i = 0; i < nbuf; i++) {
		XIOC_ST(&fr[i], i);
	}
	XIOC_ST(&b->f_head, nbuf);
	XIOC_DMB();
	XIOC_ST(&b->magic, BULK_MAGIC);
	XIOC_DMB();
}

/* bulk_valid — the attach handshake: 1 once the geometry and pre-filled free ring are
 * VISIBLE, not merely the flag. The trailing DMB pairs with bulk_init's pre-magic DMB:
 * without it the caller's subsequent nbuf/bufsz/ring reads could be satisfied ahead of
 * the magic load and see the pre-init window (codex #213). */
static inline int bulk_valid(bulk_t *b)
{
	if (XIOC_LD(&b->magic) != BULK_MAGIC) {
		return 0;
	}
	XIOC_DMB();
	return 1;
}

/* bulk_loan — pop the free ring: a buffer index the producer may fill, or -1 when the
 * pool is exhausted (counted in overflows; the producer's value is dropped-newest —
 * drop-OLDEST would mean reclaiming a buffer the consumer may hold, see the survey).
 * A loaned buffer is the producer's until published; there is no un-loan (see the
 * ownership rules above). */
static inline int bulk_loan(bulk_t *b)
{
	uint32_t t = XIOC_LD(&b->f_tail); /* producer-owned */
	uint32_t h = XIOC_LD(&b->f_head);
	if (t == h) {
		XIOC_ST(&b->overflows, XIOC_LD(&b->overflows) + 1u);
		return -1;
	}
	XIOC_DMB(); /* the entry write precedes the head we just observed */
	uint32_t idx = XIOC_LD(&bulk_free_ring(b)[t % b->nbuf]);
	XIOC_DMB(); /* the entry load completes before the tail advance is visible — without
	             * this, Arm's load->store reordering lets the far side see the slot as
	             * consumable while our read is still in flight */
	XIOC_ST(&b->f_tail, t + 1u);
	return (int)idx;
}

/* bulk_overflows — the producer's failed-loan count (REQ-BULK-002's observability:
 * back-pressure loss is a number, never silence). */
static inline uint32_t bulk_overflows(bulk_t *b)
{
	return XIOC_LD(&b->overflows);
}

/* bulk_publish — transfer a loaned+filled buffer to the consumer. The producer must not
 * touch the buffer afterwards. len rides a per-buffer cell written before the descriptor
 * (so it is in hand when the index becomes visible). */
static inline void bulk_publish(bulk_t *b, uint32_t idx, uint32_t len)
{
	XIOC_ST(&bulk_len_arr(b)[idx], len);
	uint32_t h = XIOC_LD(&b->r_head); /* producer-owned */
	XIOC_ST(&bulk_ready_ring(b)[h % b->nbuf], idx);
	XIOC_DMB(); /* payload + len + entry visible before the head moves */
	XIOC_ST(&b->r_head, h + 1u);
}

/* bulk_ready — published payloads waiting (consumer side; a poll cheap enough to sit in
 * a service loop — the P1 doorbell). */
static inline uint32_t bulk_ready(bulk_t *b)
{
	return XIOC_LD(&b->r_head) - XIOC_LD(&b->r_tail);
}

/* bulk_take — pop the oldest published buffer: its index (payload at bulk_buf(), length
 * in *len), or -1 when nothing is pending. The consumer owns the buffer until release. */
static inline int bulk_take(bulk_t *b, uint32_t *len)
{
	uint32_t t = XIOC_LD(&b->r_tail); /* consumer-owned */
	uint32_t h = XIOC_LD(&b->r_head);
	if (t == h) {
		return -1;
	}
	XIOC_DMB(); /* entry + len + payload precede the head we just observed */
	uint32_t idx = XIOC_LD(&bulk_ready_ring(b)[t % b->nbuf]);
	*len = XIOC_LD(&bulk_len_arr(b)[idx]);
	XIOC_DMB(); /* entry/len loads complete before the tail advance is visible (the
	             * load->store reordering hole — same reasoning as bulk_loan) */
	XIOC_ST(&b->r_tail, t + 1u);
	return (int)idx;
}

/* bulk_release — return a taken buffer to the pool; it may be loaned again after this.
 * CONSUMER-side only (it writes f_head): a producer never calls this — see the
 * ownership rules at the top. The DMB below also orders every prior payload read
 * before the head move, so a re-loaning producer stays off the bytes until the
 * consumer is done with them. */
static inline void bulk_release(bulk_t *b, uint32_t idx)
{
	uint32_t h = XIOC_LD(&b->f_head); /* consumer-owned */
	XIOC_ST(&bulk_free_ring(b)[h % b->nbuf], idx);
	XIOC_DMB(); /* the entry (and every prior payload read) precedes the head move */
	XIOC_ST(&b->f_head, h + 1u);
}

#endif
