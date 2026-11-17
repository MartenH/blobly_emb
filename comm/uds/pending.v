module uds

// responsePending (0x78) in an application server — generic, not routine-specific: a service whose
// answer cannot be computed in the pass that serves it (a routine's start or stop, run by an FB:
// routine.v; a 0x29 proof, verified a slice per pass: auth.v) answers 7F <sid> 78 in that pass, and
// the server then OWES its answer:
//   - the first 0x78 is the request's own answer, sent at once (as the bootloader does: work run by
//     an FB never completes within P2server — the FB's period plus a comm pass);
//   - another 0x78 follows at most pending_repeat_us (P2*server_max less a margin) after each one,
//     and the final answer when the work completes — sent even when the request set the
//     suppressPosRspMsgIndicationBit (ISO 14229-1: suppression is lifted once 0x78 was sent);
//   - every other request is DROPPED meanwhile, unanswered and unperformed (dispatch), and S3 is
//     held (pending_tick);
//   - a timeout answers the owed request conditionsNotCorrect (0x22) and asks the FB to stop at that
//     moment, the answer abandoned if the transport that asked cannot take it within
//     P2*server_max after (pending_tick) — unless the answer is READY when the timeout is judged
//     (the FB's result is in its cell: the owner reads the result cells before tick, so a result
//     the FB published before the deadline counts), which is then the answer — abandoned likewise
//     if the transport cannot take it within P2*server_max, its FB then asked to stop as when the
//     transport is gone (pending_abandon). A session entry in that window fails it (fail_owed)
//     within the same bound: an owed answer is given up at most timeout + P2*server_max after its
//     request.
// The server does not know which transport owes the answer: its owner (comm/diag Connection) does,
// and calls pending_step only when that transport can take a response. The work itself never waits
// for the transport: a routine's runs in its FB, a 0x29 verify advances in tick (pending_tick).
//
// The bootloader keeps its own responsePending (boot.Prog work_*, docs/bootloader.md) and does not
// share this one, because it differs in each part that matters there: its work (a flash erase, the
// image check) runs a unit at a time ON the serving thread, each step only once the previous
// response has left the wire (a single-bank erase stalls the whole chip); a request meanwhile is
// answered busyRepeatRequest (0x21), not dropped; a lost 0x78 is sent again a bounded number of
// times and then ends the routine refused (0x72), because an erase cannot be repeated blind; its
// uds.Server is never ticked; and boot.Prog.dispatch takes 0x31 itself, before the server. What the
// two share is the timing they announce: p2_server_us / p2_star_server_us below, which
// session_answer writes for both.

// P2server_max and P2*server_max, as every 0x10 answer announces them (session_answer) — the one
// statement of the server's timing, which a gateway's wait (comm/diagroute) is derived from too.
pub const p2_server_us = u64(50_000)
pub const p2_star_server_us = u64(5_000_000)

// pending_margin_us: how far ahead of P2*server_max a repeated 0x78 goes, for the transport and the
// pass it waits for (a comm pass is at most 10 ticks)
pub const pending_margin_us = u64(1_000_000)

// pending_repeat_us: the most between two responsePending of one owed answer
pub const pending_repeat_us = p2_star_server_us - pending_margin_us

// pending: an answer is owed (a responsePending was sent and the final answer is not)
pub fn (s &Server) pending() bool {
	return s.pend_sid != 0
}

// go_pending: service `sid` owes its answer for routine `idx` (sub-function `sub`), at most
// `timeout_us` from now; its first responsePending is this request's answer.
fn (mut s Server) go_pending(sid u8, idx int, sub u8, timeout_us u64, resp &u8) int {
	s.pend_sid = sid
	s.pend_idx = idx
	s.pend_sub = sub
	s.pend_next = s.now_us + pending_repeat_us
	s.pend_until = s.now_us + timeout_us
	s.pend_fail = false
	s.pend_late = false
	return negative(resp, sid, nrc_response_pending)
}

// pending_step: the next response of the owed answer, into resp (cap bytes) — the final answer once
// the work has completed (pending() is then false), else a responsePending when one is due, else 0.
// Call it only when the transport that owes the answer can take a response.
pub fn (mut s Server) pending_step(resp &u8, cap int) int {
	if s.pend_sid == 0 || s.resp_cap < 0 || cap < 3 || s.pend_hold {
		return 0 // nothing owed, or a count made this pass is persisted first (pend_hold)
	}
	sid := s.pend_sid
	if s.pend_fail {
		s.pend_clear()
		return negative(resp, sid, nrc_conditions_not_correct)
	}
	n := s.owed_answer(resp, cap)
	if n > 0 {
		s.pend_clear()
		return n
	}
	if s.now_us >= s.pend_next {
		s.pend_next = s.now_us + pending_repeat_us
		return negative(resp, sid, nrc_response_pending)
	}
	return 0
}

// pending_lost: a response of the owed answer did not reach the transport (a refused frame, a
// refused push): the next responsePending goes at once
pub fn (mut s Server) pending_lost() {
	if s.pend_sid != 0 {
		s.pend_next = 0
	}
}

// pending_abandon: the transport that owes the answer is gone (its DoIP connection dropped): the
// answer is no one's, and the work it waited for is asked to stop
pub fn (mut s Server) pending_abandon() {
	if s.pend_sid == 0 {
		return
	}
	if !s.pend_fail {
		s.owed_stop()
	}
	s.pend_clear()
}

// pending_tick: tick()'s share — S3 held while an answer is owed, the owed work advanced (a 0x29
// verify's slice: owed_advance), and at its timeout the owed request is failed (fail_owed) unless its
// answer is ready by then, and either is abandoned if the transport could not take it within
// P2*server_max after
fn (mut s Server) pending_tick(now u64) {
	if s.pend_sid == 0 {
		return
	}
	s.last_rx_us = now // the session does not time out under an owed answer
	s.owed_advance()
	if now < s.pend_until {
		return
	}
	if s.pend_fail || s.pend_late {
		// the transport never freed: the server serves again, and a ready answer nobody got is
		// no one's — its work asked to stop, as pending_abandon does
		if s.pend_late {
			s.owed_stop()
		}
		s.pend_clear()
	} else if s.owed_ready() {
		// the work completed in time — its result is in the cell — and only the transport is late
		s.pend_late = true
		s.pend_until = now + p2_star_server_us
	} else {
		s.fail_owed()
	}
}

// fail_owed: the owed request will be answered conditionsNotCorrect, as soon as its transport can
// take a response, and the work is asked to stop now; given up P2*server_max later — or, for a
// ready answer already waiting past its timeout (pend_late), when that wait was to end, so the
// bound on an owed answer does not grow
fn (mut s Server) fail_owed() {
	s.owed_stop()
	if !s.pend_late {
		s.pend_until = s.now_us + p2_star_server_us
	}
	s.pend_fail = true
	s.pend_late = false
	s.pend_next = 0
}

fn (mut s Server) pend_clear() {
	s.pend_sid = 0
	s.pend_idx = 0
	s.pend_sub = 0
	s.pend_next = 0
	s.pend_until = 0
	s.pend_fail = false
	s.pend_late = false
}

// owed_answer: the owed service's final answer once it is ready (0 = not yet)
fn (mut s Server) owed_answer(resp &u8, cap int) int {
	return match s.pend_sid {
		0x31 { s.routine_owed(resp, cap) }
		0x29 { s.auth_owed(resp, cap) }
		else { 0 }
	}
}

// owed_advance: the owed work's share of a pass that runs whatever the transport (pending_tick) —
// a 0x29 verify's next slice; a routine runs in its FB
fn (mut s Server) owed_advance() {
	if s.pend_sid == 0x29 {
		s.auth_advance()
	}
}

// owed_ready: owed_answer would give the final answer now
fn (s &Server) owed_ready() bool {
	return match s.pend_sid {
		0x31 { s.routine_ready() }
		0x29 { s.auth_decided }
		else { false }
	}
}

// owed_stop: the work the owed answer waited for, asked to stop — a start no longer answered
// positively, so results are not served for it
fn (mut s Server) owed_stop() {
	match s.pend_sid {
		0x31 {
			s.ask_stop(s.pend_idx)
			if s.pend_sub == 0x01 {
				s.routines[s.pend_idx].accepted = false
			}
		}
		0x29 {
			s.auth_abandon()
		}
		else {}
	}
}
