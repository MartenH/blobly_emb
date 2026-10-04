module eth

// When a DoIP answer counts as sent (driver/eth/doip_mb.h): acknowledged by the tester, not queued
// — so a reset waiting on it is never let through by an answer that dies with its connection.
// @verifies REQ-BOOT-019

#include "doip_mb.h"

fn C.doip_mb_sent_take(u32, u32, &u32, int, u32) int

fn test_an_answer_is_sent_once_the_tester_acknowledged_it() {
	mut seen := u32(0)
	// queued, not acknowledged: not sent yet
	assert C.doip_mb_sent_take(1, 1, &seen, 1, 40) == 0
	// acknowledged: sent, reported once
	assert C.doip_mb_sent_take(1, 1, &seen, 1, 0) == 1
	assert C.doip_mb_sent_take(1, 1, &seen, 1, 0) == 0
	assert seen == 1
}

fn test_a_connection_that_drops_with_the_answer_unacknowledged_never_reports_it_sent() {
	mut seen := u32(0)
	assert C.doip_mb_sent_take(2, 2, &seen, 1, 12) == 0
	// the drop: no connection, nothing pending any more — still not sent (the drop reports itself)
	assert C.doip_mb_sent_take(2, 2, &seen, 0, 0) == 0
	assert seen == 0
}

fn test_an_earlier_answers_send_says_nothing_about_this_one() {
	mut seen := u32(0)
	assert C.doip_mb_sent_take(3, 4, &seen, 1, 0) == 0
	assert seen == 3
	assert C.doip_mb_sent_take(4, 4, &seen, 1, 0) == 1
}
