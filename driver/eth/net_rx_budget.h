/* driver/eth/net_rx_budget.h — how many received frames the NetX driver (net/nx_driver_stm32h7.c)
 * takes from the MAC per kernel tick, as pure functions over a tick count, so the rule is
 * host-tested (net_rx_budget_test.v) and the driver only asks it.
 *
 * Every frame is processed on the NetX IP thread, which on an image with SOME/IP runs above the FBs
 * (loom2v net_ip_prio): the eth thread's datagrams must not wait behind an FB pass. A LAN flood must
 * still not take the FBs' CPU, so the driver takes at most `per_tick` frames in one tick and leaves
 * the rest in the DMA ring for the next tick; while it waits the ring fills, and the MAC drops what
 * does not fit — in hardware, at no CPU cost. NET_RX_PER_MS is far above what the node's own
 * traffic needs (SOME/IP events, one DoIP tester behind a 2 KiB TCP window) and far below a flood:
 * 100 Mbit/s of minimum-size frames is ~148 per millisecond. */
#ifndef BLOBLY_DRIVER_ETH_NET_RX_BUDGET_H
#define BLOBLY_DRIVER_ETH_NET_RX_BUDGET_H

#include <stdint.h>

#ifndef NET_RX_PER_MS
#define NET_RX_PER_MS 4u
#endif

typedef struct {
	uint32_t per_tick; /* frames one tick may take */
	uint32_t tick;     /* the tick `taken` counts in */
	uint32_t taken;
} net_rx_budget_t;

/* frames per tick at a kernel tick rate: NET_RX_PER_MS per millisecond, at least one per tick */
static inline uint32_t net_rx_per_tick(uint32_t ticks_per_second) {
	uint32_t n = NET_RX_PER_MS * 1000u / ticks_per_second;
	return n == 0u ? 1u : n;
}

/* may one more frame be taken at tick `now`? 1 = yes, and it is counted; 0 = this tick's budget is
 * spent. A new tick starts a new count. */
static inline int net_rx_take(net_rx_budget_t *b, uint32_t now) {
	if (now != b->tick) {
		b->tick = now;
		b->taken = 0u;
	}
	if (b->taken >= b->per_tick) {
		return 0;
	}
	b->taken++;
	return 1;
}

#endif
