module eth

import rand

// The DoIP mailbox's sequence rules (driver/eth/doip_mb.h) — the functions doip_netx.c runs on the
// target — against a reference model of the protocol around them: the doip thread posting one
// request at a time, the server's thread taking and answering it (or the doip thread withdrawing it),
// the answer collected and queued to TCP, the tester acknowledging, connections reset and recycled
// and reconnected, and the server's per-pass questions. Random interleavings, checked after every
// step. @verifies REQ-BOOT-019

#include "doip_mb.h"

@[typedef]
struct C.doip_mb_t {
mut:
	posted     u32
	settled    u32
	served     u32
	queued     u32
	reported   u32
	drops      u32
	drop_after u32
	drops_seen u32
}

fn C.doip_mb_post(&C.doip_mb_t) u32
fn C.doip_mb_waiting(&C.doip_mb_t) int
fn C.doip_mb_serve(&C.doip_mb_t)
fn C.doip_mb_withdraw(&C.doip_mb_t, u32)
fn C.doip_mb_collect(&C.doip_mb_t, u32) int
fn C.doip_mb_queue(&C.doip_mb_t)
fn C.doip_mb_drop(&C.doip_mb_t)
fn C.doip_mb_sent_take(&C.doip_mb_t, u32, u32) int
fn C.doip_mb_dropped_take(&C.doip_mb_t) int

const established = u32(5)
const close_wait = u32(6)
const closed = u32(1)
const listening = u32(2)

// ---- directed: the three shapes review found, one each ----

// an answer queued but not acknowledged is not sent; acknowledged, it is, once
fn test_an_answer_is_sent_once_the_tester_acknowledged_it() {
	mut m := C.doip_mb_t{}
	s := C.doip_mb_post(&m)
	C.doip_mb_serve(&m)
	assert C.doip_mb_collect(&m, s) == 1
	C.doip_mb_queue(&m)
	assert C.doip_mb_sent_take(&m, established, 40) == 0
	assert C.doip_mb_sent_take(&m, established, 0) == 1
	assert C.doip_mb_sent_take(&m, established, 0) == 0
}

// an RST empties the transmit queue with nothing acknowledged: not sent, whether or not the doip
// thread has recycled the connection yet; a tester that closed behind its ACKs was answered
fn test_an_empty_queue_on_a_connection_that_went_is_not_sent() {
	for state in [closed, listening] {
		mut m := C.doip_mb_t{}
		s := C.doip_mb_post(&m)
		C.doip_mb_serve(&m)
		C.doip_mb_collect(&m, s)
		C.doip_mb_queue(&m)
		assert C.doip_mb_sent_take(&m, state, 0) == 0
	}
	mut m := C.doip_mb_t{}
	s := C.doip_mb_post(&m)
	C.doip_mb_serve(&m)
	C.doip_mb_collect(&m, s)
	C.doip_mb_queue(&m)
	assert C.doip_mb_sent_take(&m, close_wait, 0) == 1
}

// A served and queued, B posted and withdrawn: A's acknowledgement is still A's
fn test_a_withdrawn_request_does_not_stand_in_for_the_served_one() {
	mut m := C.doip_mb_t{}
	a := C.doip_mb_post(&m)
	C.doip_mb_serve(&m)
	C.doip_mb_collect(&m, a)
	C.doip_mb_queue(&m)
	b := C.doip_mb_post(&m)
	assert C.doip_mb_waiting(&m) == 1
	assert C.doip_mb_collect(&m, b) == 0
	C.doip_mb_withdraw(&m, b)
	assert C.doip_mb_waiting(&m) == 0
	assert C.doip_mb_sent_take(&m, established, 0) == 1, 'A was acknowledged'
}

// ---- the reference model ----

enum Doip {
	idle    // between requests
	waiting // a request posted, its answer awaited
	ready   // its answer collected, to be sent
}

struct World {
mut:
	m C.doip_mb_t
	// the doip thread
	doip Doip
	seq  u32 // the request it posted last
	// the socket: the tester's connection, as NetX keeps it
	state    u32
	unacked  u32
	recycled bool // the doip thread has recycled a connection that went (it records the drop)
	sent_on  u32  // the answer queued last on the live connection, 0 = none
	// the server's thread: the request it served last, whether that exchange is in flight, a reset
	// its answer announced
	served   u32
	inflight bool
	reset    bool
	resets   int
	// what really happened: answers the tester acknowledged, and the latest request posted when
	// a connection was recorded as dropped
	acked     map[u32]bool
	drop_post u32
	withdrawn map[u32]bool
	reports   u32 // drops reported to the server's thread
}

fn (mut w World) server_pass() {
	if C.doip_mb_sent_take(&w.m, w.state, w.unacked) == 1 {
		assert w.served != 0 && w.acked[w.served], 'reported sent before the tester acknowledged ${w.served}'
		w.inflight = false
	}
	if C.doip_mb_dropped_take(&w.m) == 1 {
		w.reports++
		assert w.reports <= w.m.drops, 'a drop reported twice'
		if w.inflight && w.reset {
			w.reset = false // never reset unanswered
		}
		w.inflight = false
	}
	if w.reset && !w.inflight {
		assert w.acked[w.served], 'a reset with its answer unacknowledged'
		w.resets++
		w.reset = false
	}
}

fn (mut w World) step(op int) {
	match op {
		0 { // the doip thread posts a request (one at a time)
			if w.doip == .idle && w.state == established {
				w.seq = C.doip_mb_post(&w.m)
				w.doip = .waiting
			}
		}
		1 { // the server's thread takes and answers it — perhaps announcing a reset
			if C.doip_mb_waiting(&w.m) == 1 && !w.reset {
				assert w.doip == .waiting && !w.withdrawn[w.seq], 'a settled request taken'
				C.doip_mb_serve(&w.m)
				w.served = w.seq
				w.inflight = true
				w.reset = rand.intn(4) or { 1 } == 0
			}
		}
		2 { // the doip thread collects the answer, or gives up and withdraws
			if w.doip == .waiting {
				if C.doip_mb_collect(&w.m, w.seq) == 1 {
					assert w.served == w.seq
					w.doip = .ready
				} else if rand.intn(2) or { 0 } == 0 {
					assert w.served != w.seq
					C.doip_mb_withdraw(&w.m, w.seq)
					w.withdrawn[w.seq] = true
					w.doip = .idle
				}
			}
		}
		3 { // the doip thread sends the answer — or finds its connection gone and recycles it
			if w.doip == .ready {
				if w.state == established {
					C.doip_mb_queue(&w.m)
					w.unacked = 1
					w.sent_on = w.seq
				} else {
					// a send on a socket that is gone fails, and the doip thread recycles it
					C.doip_mb_drop(&w.m)
					w.drop_post = w.m.posted
					w.recycled = true
					w.state = listening
				}
				w.doip = .idle
			}
		}
		4 { // the tester acknowledges what is queued
			if w.state == established && w.unacked != 0 {
				w.unacked = 0
				w.acked[w.sent_on] = true
			}
		}
		5 { // an RST: the socket closes and NetX releases its queue, acknowledged or not
			if w.state == established {
				w.state = closed
				w.unacked = 0
				w.recycled = false
			}
		}
		6 { // the doip thread, between requests, recycles the connection that went: a drop
			if w.state != established && !w.recycled && w.doip == .idle {
				C.doip_mb_drop(&w.m)
				w.drop_post = w.m.posted
				w.recycled = true
				w.state = listening
			}
		}
		7 { // a tester connects again
			if w.recycled && w.state != established {
				w.state = established
				w.sent_on = 0
			}
		}
		else { // the server's thread passes
			w.server_pass()
		}
	}
}

fn (w &World) check(step int) {
	// a withdrawn request never counts as served
	assert !w.withdrawn[w.m.served], 'step ${step}: withdrawn ${w.m.served} counted as served'
	// in flight clears only once the served answer was acknowledged, or its connection dropped
	if w.served != 0 && !w.inflight {
		assert w.acked[w.served] || w.drop_post >= w.served, 'step ${step}: ${w.served} cleared early'
	}
}

// pick weights the operations: the protocol's steps often, a connection reset now and then
fn pick(r int) int {
	return match r {
		0...4 { 0 } // post
		5...9 { 1 } // serve
		10...14 { 2 } // collect / withdraw
		15...19 { 3 } // send
		20...24 { 4 } // acknowledge
		25 { 5 } // RST
		26, 27 { 6 } // recycle
		28, 29 { 7 } // reconnect
		else { 8 } // a server pass
	}
}

fn test_the_mailbox_against_the_reference_model() {
	rand.seed([u32(0xD01B), 0x2026])
	mut total := 0
	for run in 0 .. 200 {
		mut w := World{
			state: established
		}
		for step in 0 .. 200 {
			w.step(pick(rand.intn(40) or { 0 }))
			w.check(step)
		}
		// nothing stays in flight: once the doip thread has sent the answer and the tester has
		// acknowledged it — or the doip thread has recycled the connection it went with — the next
		// pass settles it
		if w.doip == .waiting && w.served != w.seq {
			C.doip_mb_withdraw(&w.m, w.seq) // not taken: the doip thread gives up on it
			w.withdrawn[w.seq] = true
			w.doip = .idle
		}
		if w.doip == .waiting {
			w.step(2)
		}
		if w.doip == .ready {
			w.step(3)
		}
		w.step(4)
		if w.state != established && !w.recycled && w.doip == .idle {
			w.step(6)
		}
		w.server_pass()
		assert !w.inflight, 'run ${run}: ${w.served} stays in flight (doip ${w.doip}, state ${w.state})'
		total += w.resets
	}
	assert total > 50, 'the walk never reached a reset'
}
