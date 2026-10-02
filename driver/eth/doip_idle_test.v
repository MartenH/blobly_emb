module eth

// ISO 13400 inactivity (driver/eth/doip_idle.h), the rules doip_netx.c runs on the target, tested
// on the host through every event order review found: a pipelined activation, a late answer, an
// answer in time, the absolute initial timer, and tick wrap.

#include "doip_idle.h"

@[typedef]
struct C.doip_idle_t {
mut:
	initial       u32
	general       u32
	conn_start    u32
	last_activity u32
	activated     int
}

fn C.doip_idle_accept(&C.doip_idle_t, u32)
fn C.doip_idle_rx(&C.doip_idle_t, u32)
fn C.doip_idle_tx(&C.doip_idle_t, u32)
fn C.doip_idle_activated(&C.doip_idle_t, int)
fn C.doip_idle_left(&C.doip_idle_t, u32) u32

fn idle(initial u32, general u32, t0 u32) C.doip_idle_t {
	mut s := C.doip_idle_t{
		initial: initial
		general: general
	}
	C.doip_idle_accept(&s, t0)
	return s
}

fn test_the_initial_timer_is_absolute_from_accept() {
	mut s := idle(100, 1000, 0)
	C.doip_idle_rx(&s, 60) // trickled bytes do not extend it
	assert C.doip_idle_left(&s, 60) == 40
	assert C.doip_idle_left(&s, 100) == 0
}

fn test_the_general_timer_runs_from_the_last_traffic() {
	mut s := idle(100, 1000, 0)
	C.doip_idle_rx(&s, 10)
	C.doip_idle_activated(&s, 1)
	C.doip_idle_tx(&s, 50) // the activation response, in time: activity
	assert C.doip_idle_left(&s, 1049) == 1
	assert C.doip_idle_left(&s, 1050) == 0
	C.doip_idle_rx(&s, 900)
	assert C.doip_idle_left(&s, 1500) == 400
}

// codex round 5: an answer produced past the deadline goes out, but does not revive the connection
fn test_a_late_answer_does_not_revive_an_expired_connection() {
	mut s := idle(100, 1000, 0)
	C.doip_idle_rx(&s, 0)
	C.doip_idle_activated(&s, 1)
	C.doip_idle_tx(&s, 1500)
	assert C.doip_idle_left(&s, 1500) == 0
}

// codex round 6: activation and a request in one chunk, served for longer than the limit; the
// loop reports the activation only after the answer — the clock runs from the activation's bytes
fn test_a_pipelined_activation_keeps_its_receive_time() {
	mut s := idle(100, 1000, 0)
	C.doip_idle_rx(&s, 5)
	C.doip_idle_tx(&s, 2005) // still not activated as far as the timer knows
	C.doip_idle_activated(&s, 1)
	assert C.doip_idle_left(&s, 2005) == 0
	// the same in time keeps the connection
	mut t := idle(100, 3000, 0)
	C.doip_idle_rx(&t, 5)
	C.doip_idle_tx(&t, 2005)
	C.doip_idle_activated(&t, 1)
	assert C.doip_idle_left(&t, 2005) == 1000
}

fn test_a_new_connection_starts_unactivated() {
	mut s := idle(100, 1000, 0)
	C.doip_idle_activated(&s, 1)
	C.doip_idle_accept(&s, 5000)
	assert C.doip_idle_left(&s, 5050) == 50 // the initial timer again
}

fn test_ticks_wrap() {
	t0 := u32(0xFFFF_FFF0)
	mut s := idle(100, 1000, t0)
	assert C.doip_idle_left(&s, t0 + 50) == 50 // across the wrap
	C.doip_idle_rx(&s, t0 + 60)
	C.doip_idle_activated(&s, 1)
	assert C.doip_idle_left(&s, t0 + 1059) == 1
}
