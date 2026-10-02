/* driver/eth/doip_idle.h — ISO 13400 inactivity for one DoIP connection, as pure functions over a
 * tick count, so the rules are host-tested (doip_idle_test.v) and doip_netx.c only feeds events.
 *
 *   T_TCP_Initial_Inactivity  before routing activation: ABSOLUTE from accept — trickled bytes do
 *                             not extend it.
 *   T_TCP_General_Inactivity  after it: from the last DoIP traffic either way. Received bytes
 *                             restart it; an answer sent restarts it only while it has not already
 *                             expired (a late answer goes out but does not revive the connection);
 *                             and it runs from the bytes that carried the activation, not from when
 *                             the loop noticed — the request pipelined behind an activation may take
 *                             longer to serve than the limit.
 * Ticks are wrap-safe (unsigned differences). */
#ifndef BLOBLY_DRIVER_ETH_DOIP_IDLE_H
#define BLOBLY_DRIVER_ETH_DOIP_IDLE_H

#include <stdint.h>

typedef struct {
	uint32_t initial;       /* T_TCP_Initial_Inactivity, ticks */
	uint32_t general;       /* T_TCP_General_Inactivity, ticks */
	uint32_t conn_start;    /* accept */
	uint32_t last_activity; /* the last bytes received, or an answer sent in time */
	int activated;
} doip_idle_t;

static inline void doip_idle_accept(doip_idle_t *s, uint32_t now) {
	s->conn_start = now;
	s->last_activity = now;
	s->activated = 0;
}

static inline void doip_idle_rx(doip_idle_t *s, uint32_t now) {
	s->last_activity = now;
}

/* ticks left before the deadline that is running; 0 = expired */
static inline uint32_t doip_idle_left(const doip_idle_t *s, uint32_t now) {
	uint32_t base = s->activated ? s->last_activity : s->conn_start;
	uint32_t lim = s->activated ? s->general : s->initial;
	uint32_t el = now - base;
	return el >= lim ? 0u : lim - el;
}

static inline void doip_idle_tx(doip_idle_t *s, uint32_t now) {
	if (s->activated && doip_idle_left(s, now) != 0u) {
		s->last_activity = now;
	}
}

/* the loop reports the activation state after serving a chunk: last_activity is left as the time
 * the activation's bytes arrived */
static inline void doip_idle_activated(doip_idle_t *s, int on) {
	s->activated = on;
}

#endif
