/* driver/eth/doip_mb.h — when the answer the server gave last counts as SENT over DoIP, as a pure
 * function so the rule is host-tested (doip_mb_test.v) and doip_netx.c only feeds it.
 *
 * Sent means the tester ACKNOWLEDGED it, not that NetX queued it: a reset waits for its answer to be
 * sent (comm/diag Connection.reset_due, boot.Prog.reset_due), and an answer still in TCP's
 * transmit queue dies with a connection that drops — which must cancel the reset, never let it
 * through. So nothing is reported while the connection is down or bytes are unacknowledged: a drop
 * then reports itself (doip_mb_take_dropped) with the answer still in flight. */
#ifndef BLOBLY_DRIVER_ETH_DOIP_MB_H
#define BLOBLY_DRIVER_ETH_DOIP_MB_H

#include <stdint.h>

/* sent_seq: the answer handed to TCP last; answered: the one the server gave last; *seen: the last
 * one reported (updated); connected / unacked: the TCP connection and its unacknowledged bytes.
 * 1 = report the answer sent, once. */
static inline int doip_mb_sent_take(uint32_t sent_seq, uint32_t answered, uint32_t *seen, int connected,
                                    uint32_t unacked) {
	if (sent_seq != answered) {
		*seen = sent_seq; /* an earlier answer's send: nothing to say about this one */
		return 0;
	}
	if (sent_seq == *seen || !connected || unacked != 0u) {
		return 0; /* reported already, or not acknowledged yet */
	}
	*seen = sent_seq;
	return 1;
}

#endif
