/* driver/eth/doip_mb.h — when the answer the server gave last counts as SENT over DoIP, as a pure
 * function so the rule is host-tested (doip_mb_test.v) and doip_netx.c only feeds it.
 *
 * Sent means the tester ACKNOWLEDGED it, not that NetX queued it: a reset waits for its answer to be
 * sent (comm/diag Connection.reset_due, boot.Prog.reset_due), and an answer still in TCP's
 * transmit queue dies with a connection that drops — which must cancel the reset, never let it
 * through. So nothing is reported unless the socket is in a state where an empty transmit queue
 * means acknowledged: ESTABLISHED, or CLOSE_WAIT (the tester closed after acknowledging — a FIN
 * arrives in sequence, behind its ACKs). An RST releases the queue too (it empties with nothing
 * acknowledged) but leaves the socket CLOSED or listening, so it is never read as an
 * acknowledgement, whether or not the doip thread has recycled the connection yet; the drop then
 * reports itself (doip_mb_take_dropped) with the answer still in flight. */
#ifndef BLOBLY_DRIVER_ETH_DOIP_MB_H
#define BLOBLY_DRIVER_ETH_DOIP_MB_H

#include <stdint.h>

/* the TCP states this rule reads, NetX's numbering (nx_api.h; doip_netx.c checks they agree) */
#define DOIP_MB_TCP_ESTABLISHED 5u
#define DOIP_MB_TCP_CLOSE_WAIT 6u

/* sent_seq: the answer handed to TCP last; answered: the one the server gave last; *seen: the last
 * one reported (updated); state / unacked: the socket's TCP state and its unacknowledged bytes,
 * read together. 1 = report the answer sent, once. */
static inline int doip_mb_sent_take(uint32_t sent_seq, uint32_t answered, uint32_t *seen, uint32_t state,
                                    uint32_t unacked) {
	if (sent_seq != answered) {
		*seen = sent_seq; /* an earlier answer's send: nothing to say about this one */
		return 0;
	}
	if (sent_seq == *seen || unacked != 0u ||
	    (state != DOIP_MB_TCP_ESTABLISHED && state != DOIP_MB_TCP_CLOSE_WAIT)) {
		return 0; /* reported already, or not acknowledged (yet, or ever: the connection went) */
	}
	*seen = sent_seq;
	return 1;
}

#endif
