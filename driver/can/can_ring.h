#ifndef BLOBLY_CAN_RING_H
#define BLOBLY_CAN_RING_H
#include <stdint.h>
#include <string.h>

/* Lock-free single-producer / single-consumer ring of CAN frames.
 *
 * Callback-driven backends (AUTOSAR CanIf RxIndication, an FDCAN Rx ISR) are
 * the sole PRODUCER; the bridge tick (blob_can_recv) is the sole CONSUMER. No
 * locks — valid only under that SPSC discipline, the same rule that makes the
 * IOC safe. The acquire/release pairing on head/tail orders the payload copy
 * against the index publish on weakly-ordered cores (Cortex-M7). */

#ifndef BLOB_CAN_RING_CAP
#define BLOB_CAN_RING_CAP 32u            /* must be a power of two */
#endif

typedef struct {
	uint32_t id;
	uint8_t  len;
	uint8_t  data[64];
} blob_can_msg;

typedef struct {
	blob_can_msg slot[BLOB_CAN_RING_CAP];
	volatile uint32_t head;              /* producer advances */
	volatile uint32_t tail;              /* consumer advances */
} blob_can_ring;

/* producer: 0 on success, -1 if full (frame dropped — log/count in the caller). */
static inline int blob_ring_push(blob_can_ring *r, uint32_t id, const uint8_t *d, uint8_t len) {
	uint32_t h = __atomic_load_n(&r->head, __ATOMIC_RELAXED);
	uint32_t t = __atomic_load_n(&r->tail, __ATOMIC_ACQUIRE);
	if ((h - t) >= BLOB_CAN_RING_CAP) return -1;          /* full */
	if (len > 64) len = 64;
	blob_can_msg *m = &r->slot[h & (BLOB_CAN_RING_CAP - 1u)];
	m->id = id;
	m->len = len;
	memcpy(m->data, d, len);
	__atomic_store_n(&r->head, h + 1u, __ATOMIC_RELEASE); /* publish after the copy */
	return 0;
}

/* consumer: 0 and fills out on success, -1 if empty. */
static inline int blob_ring_pop(blob_can_ring *r, uint32_t *id, uint8_t *d, uint8_t *len) {
	uint32_t t = __atomic_load_n(&r->tail, __ATOMIC_RELAXED);
	uint32_t h = __atomic_load_n(&r->head, __ATOMIC_ACQUIRE);
	if (h == t) return -1;                                /* empty */
	blob_can_msg *m = &r->slot[t & (BLOB_CAN_RING_CAP - 1u)];
	*id = m->id;
	*len = m->len;
	memcpy(d, m->data, m->len);
	__atomic_store_n(&r->tail, t + 1u, __ATOMIC_RELEASE); /* free the slot after the copy */
	return 0;
}

#endif
