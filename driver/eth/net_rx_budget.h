/* driver/eth/net_rx_budget.h — how much of the NetX IP thread's receive work runs at its own
 * priority, as pure functions over a tick count, so the rule is host-tested (net_rx_budget_test.v)
 * and the driver (net/nx_driver_stm32h7.c) only asks it.
 *
 * Every frame is processed on the NetX IP thread, which on an image with an eth thread runs above
 * the FBs (loom2v net_ip_prio): the eth thread's datagrams must not wait behind an FB pass. A LAN
 * flood must still not take the FBs' CPU. So each tick the driver takes `per_tick` frames at that
 * priority; the frame after them demotes the IP thread below every application thread (loom2v
 * doip_net_prio) and the driver goes on draining the ring there — on CPU the FBs leave idle, as
 * the IP thread did when it always ran below them. The first time the driver runs in a later tick,
 * the IP thread gets its priority back.
 *
 * Nothing is held back, so a flood costs the node no reachability it had with the IP thread at the
 * bottom: the tester's TCP SYN in a flood is as likely to be taken as any other frame. Only the
 * share of that work that may preempt an FB is bounded. NET_RX_PER_MS is far above what the node's
 * own traffic needs (SOME/IP events, one DoIP tester behind a 2 KiB TCP window) and far below a
 * flood: 100 Mbit/s of minimum-size frames is ~148 per millisecond. */
#ifndef BLOBLY_DRIVER_ETH_NET_RX_BUDGET_H
#define BLOBLY_DRIVER_ETH_NET_RX_BUDGET_H

#include <stdint.h>

#ifndef NET_RX_PER_MS
#define NET_RX_PER_MS 4u
#endif

typedef struct {
	uint32_t per_tick; /* frames one tick takes at the IP thread's own priority */
	uint32_t tick;     /* the tick `taken` counts in */
	uint32_t taken;
	int low;           /* demoted: the rest of `tick` runs below the application threads */
} net_rx_budget_t;

/* frames per tick at a kernel tick rate: NET_RX_PER_MS per millisecond, at least one per tick */
static inline uint32_t net_rx_per_tick(uint32_t ticks_per_second) {
	uint32_t n = NET_RX_PER_MS * 1000u / ticks_per_second;
	return n == 0u ? 1u : n;
}

/* the driver is entered at tick `now`: 1 = give the IP thread its priority back (it was demoted in
 * an earlier tick) */
static inline int net_rx_enter(net_rx_budget_t *b, uint32_t now) {
	if (b->low && now != b->tick) {
		b->low = 0;
		return 1;
	}
	return 0;
}

/* a frame was received at tick `now`, before it is handed up: 1 = demote the IP thread now — this
 * tick's budget is spent and it still runs at its own priority. A new tick starts a new count.
 * Asked only for a frame that exists, so an empty ring never demotes. */
static inline int net_rx_over(net_rx_budget_t *b, uint32_t now) {
	if (b->low) {
		return 0;
	}
	if (now != b->tick) {
		b->tick = now;
		b->taken = 0u;
	}
	if (b->taken < b->per_tick) {
		return 0;
	}
	b->low = 1;
	return 1;
}

/* a frame was taken */
static inline void net_rx_took(net_rx_budget_t *b) {
	b->taken++;
}

#endif
