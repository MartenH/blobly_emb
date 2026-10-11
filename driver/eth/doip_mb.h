/* driver/eth/doip_mb.h — the sequence rules of the DoIP mailbox (driver/eth/doip_netx.c), as pure
 * functions over one state, so the whole protocol is host-tested against a reference model
 * (doip_mb_test.v) and doip_netx.c only locks, copies and feeds it.
 *
 * The doip thread POSTS one request at a time and waits; the server's thread (the application's
 * comm thread, or the bootloader's serve loop) TAKES it and ANSWERS it — it is then SERVED — or, not
 * taken in time, the doip thread WITHDRAWS it, and it is settled without ever having been served.
 * The doip thread COLLECTS a served answer and QUEUES it to TCP. The server's thread asks two things
 * each pass, about the request it served last and nothing else:
 *   doip_mb_sent_take    — its answer has been ACKNOWLEDGED by the tester: queued, nothing left
 *                          unacknowledged, on a socket still ESTABLISHED or in CLOSE_WAIT (the
 *                          tester closed behind its ACKs). An RST empties the queue with nothing
 *                          acknowledged but leaves the socket CLOSED or listening, so it is never
 *                          read as an acknowledgement; a reset waiting on the answer waits on;
 *   doip_mb_dropped_take — a connection dropped after that request was posted: the answer, if not
 *                          acknowledged, died with it (a reset it announced is cancelled).
 * A withdrawn request is never served, so it never stands in for the served one: an answer still
 * in flight is acknowledged, or dropped, whatever was withdrawn after it.
 *
 * The server's thread may PUSH a further response to the request it served last (a routine
 * answered responsePending, then its next step's response). A push has its OWN sequence: it is
 * queued when the doip thread sends it, and reported sent (doip_mb_push_sent_take) only once THAT
 * push is acknowledged — never by the acknowledgement of an answer to some other request, which may
 * have gone out while the push still waited to be taken.
 *
 * Fields written by one thread and read by another are single aligned words; doip_netx.c holds
 * its mailbox mutex around post / take / answer / withdraw / collect. */
#ifndef BLOBLY_DRIVER_ETH_DOIP_MB_H
#define BLOBLY_DRIVER_ETH_DOIP_MB_H

#include <stdint.h>

/* the TCP states this rule reads, NetX's numbering (nx_api.h; doip_netx.c checks they agree) */
#define DOIP_MB_TCP_ESTABLISHED 5u
#define DOIP_MB_TCP_CLOSE_WAIT 6u

typedef struct {
	volatile uint32_t posted;     /* the request posted last */
	volatile uint32_t settled;    /* the request settled last: served, or withdrawn */
	volatile uint32_t served;     /* the request the server answered last (never a withdrawn one) */
	volatile uint32_t queued;     /* the served answer handed to TCP last */
	volatile uint32_t reported;   /* the served answer reported acknowledged last */
	volatile uint32_t drops;      /* connections dropped */
	volatile uint32_t drop_after; /* the request posted last when the latest one dropped */
	volatile uint32_t drops_seen; /* the server thread's last reading of drops */
	volatile uint32_t pushed;        /* further responses pushed by the server thread */
	volatile uint32_t push_taken;    /* ... taken by the doip thread */
	volatile uint32_t push_queued;   /* ... the push handed to TCP last */
	volatile uint32_t push_reported; /* ... the push reported acknowledged last */
} doip_mb_t;

/* doip thread: a new request; its sequence */
static inline uint32_t doip_mb_post(doip_mb_t *m) {
	m->posted = m->posted + 1u;
	return m->posted;
}

/* server thread: a request is waiting to be taken */
static inline int doip_mb_waiting(const doip_mb_t *m) {
	return m->settled != m->posted;
}

/* server thread: the waiting request is answered */
static inline void doip_mb_serve(doip_mb_t *m) {
	m->served = m->posted;
	m->settled = m->posted;
}

/* doip thread: request `seq`, not taken in time, is withdrawn — settled, never served */
static inline void doip_mb_withdraw(doip_mb_t *m, uint32_t seq) {
	m->settled = seq;
}

/* doip thread: 1 when request `seq` has been served — its answer is there to collect */
static inline int doip_mb_collect(const doip_mb_t *m, uint32_t seq) {
	return m->served == seq;
}

/* doip thread: a response went to TCP — it carries the answer served last, or follows it (the doip
 * thread posts the next request only after sending this one's answer) */
static inline void doip_mb_queue(doip_mb_t *m) {
	m->queued = m->served;
}

/* doip thread: the push taken last went to TCP. Only a push actually sent is queued — one taken
 * with no tester to send it to (its connection gone) never is, whatever goes out after it. */
static inline void doip_mb_push_queue(doip_mb_t *m) {
	m->push_queued = m->push_taken;
}

/* doip thread: the connection dropped — and whatever it had queued with it: an answer queued on
 * a connection that is gone is never acknowledged, whatever the next connection's queue says */
static inline void doip_mb_drop(doip_mb_t *m) {
	m->queued = 0u;
	m->push_queued = 0u;
	m->push_taken = m->pushed; /* a push still waiting was for the tester that went: never sent */
	m->drop_after = m->posted;
	m->drops = m->drops + 1u;
}

/* server thread: push a further response to the request served last — in flight until THIS push
 * is queued and acknowledged (doip_mb_push_sent_take). The server pushes again only once it has
 * been: the single push slot is never overwritten. */
static inline void doip_mb_push(doip_mb_t *m) {
	m->pushed = m->pushed + 1u;
}

/* doip thread: 1 when a pushed response waits to be sent (taking it) */
static inline int doip_mb_push_take(doip_mb_t *m) {
	if (m->push_taken == m->pushed) {
		return 0;
	}
	m->push_taken = m->pushed;
	return 1;
}

/* server thread: 1 once the answer it served last has been acknowledged (above), reported once;
 * state / unacked: the socket's TCP state and its unacknowledged bytes, read together */
static inline int doip_mb_sent_take(doip_mb_t *m, uint32_t state, uint32_t unacked) {
	uint32_t s = m->served;
	if (s == m->reported || m->queued != s || unacked != 0u ||
	    (state != DOIP_MB_TCP_ESTABLISHED && state != DOIP_MB_TCP_CLOSE_WAIT)) {
		return 0;
	}
	m->reported = s;
	return 1;
}

/* server thread: 1 once the push it made last has itself been acknowledged (the rule of
 * doip_mb_sent_take, for the push's own sequence), reported once */
static inline int doip_mb_push_sent_take(doip_mb_t *m, uint32_t state, uint32_t unacked) {
	uint32_t p = m->pushed;
	if (p == m->push_reported || m->push_queued != p || unacked != 0u ||
	    (state != DOIP_MB_TCP_ESTABLISHED && state != DOIP_MB_TCP_CLOSE_WAIT)) {
		return 0;
	}
	m->push_reported = p;
	return 1;
}

/* server thread: 1 while a dropped connection has not been taken yet (doip_mb_dropped_take) — a
 * gateway's router judges no routed request meanwhile: the unlock it reads is still the dropped
 * tester's until the server has heard of the drop (REQ-NET-020) */
static inline int doip_mb_drop_pending(const doip_mb_t *m) {
	return m->drops != m->drops_seen;
}

/* server thread: 1 once a connection has dropped that the request it served last came over — a
 * drop before that request was posted belongs to a tester whose state is already superseded */
static inline int doip_mb_dropped_take(doip_mb_t *m) {
	uint32_t d = m->drops;
	int r = d != m->drops_seen && m->drop_after >= m->served;
	m->drops_seen = d;
	if (r) {
		m->push_taken = m->pushed; /* a push made before the server heard: never sent to anyone */
	}
	return r;
}

#endif
