module eth

// the receive budget (driver/eth/net_rx_budget.h) the NetX driver applies on the target: how many
// frames one tick may hand to the IP thread, tested on the host.

#include "net_rx_budget.h"

@[typedef]
struct C.net_rx_budget_t {
mut:
	per_tick u32
	tick     u32
	taken    u32
}

fn C.net_rx_per_tick(u32) u32
fn C.net_rx_room(&C.net_rx_budget_t, u32) int
fn C.net_rx_took(&C.net_rx_budget_t)

fn budget(per_tick u32) C.net_rx_budget_t {
	return C.net_rx_budget_t{
		per_tick: per_tick
	}
}

// takes: the driver's loop over a ring holding `n` frames — ask, then take one
fn takes(mut b C.net_rx_budget_t, now u32, n int) int {
	mut got := 0
	for _ in 0 .. n {
		if C.net_rx_room(&b, now) == 0 {
			break
		}
		C.net_rx_took(&b)
		got++
	}
	return got
}

fn test_a_tick_takes_its_budget_and_no_more() {
	mut b := budget(4)
	assert takes(mut b, 7, 10) == 4
	assert C.net_rx_room(&b, 7) == 0
}

// the driver asks before every receive, and the last ask of a pass finds the ring empty: asking
// must not spend the budget, or ordinary traffic gets half of it
fn test_asking_takes_nothing() {
	mut b := budget(4)
	for _ in 0 .. 4 {
		assert C.net_rx_room(&b, 7) == 1
		C.net_rx_took(&b)
		assert C.net_rx_room(&b, 7) == (if b.taken < 4 { 1 } else { 0 }) // the empty look
	}
	assert b.taken == 4
}

fn test_the_next_tick_starts_a_new_count() {
	mut b := budget(4)
	assert takes(mut b, 7, 10) == 4
	assert takes(mut b, 8, 10) == 4
	// a tick that took less leaves nothing over for the next
	assert takes(mut b, 9, 1) == 1
	assert takes(mut b, 10, 10) == 4
}

fn test_ticks_wrap() {
	mut b := budget(2)
	assert takes(mut b, 0xFFFF_FFFF, 5) == 2
	assert takes(mut b, 0, 5) == 2
}

// the rate is per millisecond whatever the tick: a 1 kHz tick takes 4, a 100 Hz one 40, and a tick
// too short for one frame at that rate still takes one
fn test_the_budget_follows_the_tick_rate() {
	assert C.net_rx_per_tick(1000) == 4
	assert C.net_rx_per_tick(100) == 40
	assert C.net_rx_per_tick(10000) == 1
}
