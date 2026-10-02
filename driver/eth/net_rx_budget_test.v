module eth

// the receive budget (driver/eth/net_rx_budget.h) the NetX driver applies on the target: how many
// frames a tick takes at the IP thread's own priority before it drops below the application
// threads, and when it gets that priority back — tested on the host.

#include "net_rx_budget.h"

@[typedef]
struct C.net_rx_budget_t {
mut:
	per_tick u32
	tick     u32
	taken    u32
	low      int
}

fn C.net_rx_per_tick(u32) u32
fn C.net_rx_enter(&C.net_rx_budget_t, u32) int
fn C.net_rx_over(&C.net_rx_budget_t, u32) int
fn C.net_rx_took(&C.net_rx_budget_t)

fn budget(per_tick u32) C.net_rx_budget_t {
	return C.net_rx_budget_t{
		per_tick: per_tick
	}
}

struct Pass {
	restored bool // the IP thread got its priority back on entry
	high     int  // frames taken at its own priority
	low      int  // frames taken after it demoted itself
}

// pass: one driver pass over a ring holding `n` frames, as the driver runs it — enter, then for
// every frame received ask, demote when told to, take it; the drain never stops early, and the look
// that finds the ring empty asks nothing
fn pass(mut b C.net_rx_budget_t, now u32, n int) Pass {
	restored := C.net_rx_enter(&b, now) == 1
	mut high := 0
	mut low := 0
	for _ in 0 .. n {
		C.net_rx_over(&b, now)
		C.net_rx_took(&b)
		if b.low != 0 {
			low++
		} else {
			high++
		}
	}
	return Pass{restored, high, low}
}

fn test_traffic_within_the_budget_never_demotes() {
	mut b := budget(4)
	for t in u32(1) .. 100 {
		assert pass(mut b, t, 4) == Pass{false, 4, 0}
	}
}

// exactly the budget in one tick, over two passes, all at the IP thread's own priority
fn test_the_budget_is_per_tick_not_per_pass() {
	mut b := budget(4)
	assert pass(mut b, 7, 2) == Pass{false, 2, 0}
	assert pass(mut b, 7, 2) == Pass{false, 2, 0}
	assert b.low == 0
	assert pass(mut b, 7, 1) == Pass{false, 0, 1}
}

// a flood: the budget at the IP thread's priority, everything else below the application threads
// — drained, not left in the ring
fn test_a_flood_drains_below_the_fbs() {
	mut b := budget(4)
	assert pass(mut b, 7, 100) == Pass{false, 4, 96}
	// the rest of that tick stays low, however often the driver runs
	assert pass(mut b, 7, 10) == Pass{false, 0, 10}
	// the next tick gives the priority back and counts anew
	assert pass(mut b, 8, 10) == Pass{true, 4, 6}
}

// the IP thread got the CPU again only ticks later (the FBs were busy): restored on entry all the same
fn test_a_late_tick_restores() {
	mut b := budget(4)
	assert pass(mut b, 7, 5) == Pass{false, 4, 1}
	assert pass(mut b, 50, 1) == Pass{true, 1, 0}
	assert b.low == 0
}

fn test_ticks_wrap() {
	mut b := budget(2)
	assert pass(mut b, 0xFFFF_FFFF, 5) == Pass{false, 2, 3}
	assert pass(mut b, 0, 5) == Pass{true, 2, 3}
}

// the rate is per millisecond whatever the tick: a 1 kHz tick takes 4, a 100 Hz one 40, and a tick
// too short for one frame at that rate still takes one
fn test_the_budget_follows_the_tick_rate() {
	assert C.net_rx_per_tick(1000) == 4
	assert C.net_rx_per_tick(100) == 40
	assert C.net_rx_per_tick(10000) == 1
}
