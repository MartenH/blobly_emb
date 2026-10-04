module eth

// When a DoIP answer counts as sent (driver/eth/doip_mb.h): acknowledged by the tester on a
// connection that is still there, not queued — so a reset waiting on it is never let through by an
// answer that dies with its connection. @verifies REQ-BOOT-019

#include "doip_mb.h"

fn C.doip_mb_sent_take(u32, u32, &u32, u32, u32) int

const established = u32(5)
const close_wait = u32(6)
const closed = u32(1)
const listening = u32(2)

fn test_an_answer_is_sent_once_the_tester_acknowledged_it() {
	mut seen := u32(0)
	// queued, not acknowledged: not sent yet
	assert C.doip_mb_sent_take(1, 1, &seen, established, 40) == 0
	// acknowledged: sent, reported once
	assert C.doip_mb_sent_take(1, 1, &seen, established, 0) == 1
	assert C.doip_mb_sent_take(1, 1, &seen, established, 0) == 0
	assert seen == 1
}

// an RST releases the transmit queue with nothing acknowledged: an empty queue on a socket that is
// no longer established is not an acknowledgement, recycled by the doip thread yet or not
fn test_an_empty_queue_on_a_connection_that_went_is_not_sent() {
	for state in [closed, listening] {
		mut seen := u32(0)
		assert C.doip_mb_sent_take(2, 2, &seen, established, 12) == 0
		assert C.doip_mb_sent_take(2, 2, &seen, state, 0) == 0
		assert seen == 0
	}
}

// a tester that closes after acknowledging (CLOSE_WAIT: its FIN came behind its ACKs) was answered
fn test_a_tester_that_closed_after_acknowledging_was_answered() {
	mut seen := u32(0)
	assert C.doip_mb_sent_take(3, 3, &seen, close_wait, 0) == 1
}

fn test_an_earlier_answers_send_says_nothing_about_this_one() {
	mut seen := u32(0)
	assert C.doip_mb_sent_take(3, 4, &seen, established, 0) == 0
	assert seen == 3
	assert C.doip_mb_sent_take(4, 4, &seen, established, 0) == 1
}
