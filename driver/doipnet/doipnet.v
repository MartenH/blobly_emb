module doipnet

import comm.diagroute
import comm.doip

// The DoIP entity's network loop: the vehicle announcements, then one tester connection at a
// time, its TCP bytes fed to comm/doip's framing and the response stream sent back. ONE loop for
// every image that serves DoIP — a node's application (loom2v [doip]) and its bootloader
// (boot/target, a [boot] node with [doip]) — over driver/eth/doip_netx.c's stream
// (netx_d_freestanding.v), or a fake one in the tests.
//
// A stream S answers:
//   recv(buf &u8, max int) int  >0 bytes received, 0 nothing yet, <0 the connection dropped
//                               (the C side already recycled it)
//   send(buf &u8, n int) int    <0 the send failed and the connection was recycled
//   drop()                      close the connection once the response written so far is sent
//   activated(on bool)          whether routing is active (the short initial inactivity limit
//                               holds until it is)

// pass is one receive and everything it completes: every whole DoIP message the bytes finish is
// served, and each response the framing writes is sent before the next is made (feed stops when
// its response buffer fills, and is drained with zero-length feeds). A connection the framing
// condemns (a desynced stream's NACK, a refused activation) is dropped once that response is out.
// inb holds doip.max_msg bytes, out doip.max_resp.
pub fn pass[S](mut st S, mut s doip.Server, inb &u8, out &u8) {
	// only what the assembly buffer can still take
	n := st.recv(inb, doip.max_msg - s.buf_len)
	if n < 0 {
		end(mut st, mut s)
		return
	}
	if n == 0 {
		return
	}
	// serve what the bytes complete, a response buffer at a time
	mut fed := n
	for {
		rlen := s.feed(inb, fed, out, doip.max_resp)
		if rlen <= 0 {
			break
		}
		if st.send(out, rlen) < 0 {
			end(mut st, mut s) // the C side recycled the connection
			break
		}
		fed = 0
	}
	if s.fatal {
		st.drop()
		end(mut st, mut s)
	}
	st.activated(s.activated)
}

// push sends a further response the server pushed to the request it answered last (a routine's
// next responsePending, its answer): to the activated tester, as a diagnostic message. With no
// tester activated the connection it belonged to is gone — the drop is what the server hears.
// True when it went to TCP (doip_mb_push_queue: only a push actually sent is ever acknowledged).
pub fn push[S](mut st S, mut s doip.Server, resp &u8, n int, out &u8) bool {
	if !s.activated {
		return false
	}
	if st.send(out, s.response_message(resp, n, out)) < 0 {
		end(mut st, mut s) // the C side recycled the connection
		return false
	}
	return true
}

// routed sends an answer of a node behind the gateway (`from`) to the request numbered `ticket`:
// only to the latest routed request, and only while its tester is still connected — an answer that
// came after the tester gave up, or after its connection ended, is no one's.
pub fn routed[S](mut st S, mut s doip.Server, from u16, ticket u32, ans &u8, n int, out &u8) bool {
	if !s.activated || ticket != s.ticket || n <= 0 {
		return false
	}
	if st.send(out, s.routed_message(from, ans, n, out)) < 0 {
		end(mut st, mut s) // the C side recycled the connection
		return false
	}
	return true
}

// verdict_code: the diagnostic-message NACK code for the router's verdict (0 = forwarded)
pub fn verdict_code(v diagroute.Verdict) int {
	return match v {
		.accepted { 0 }
		.unknown_target { int(doip.dnack_unknown_target) }
		.locked { int(doip.dnack_unreachable) }
		.busy { int(doip.dnack_out_of_memory) }
		.refused { int(doip.dnack_transport_error) }
	}
}

// end resets the framing state for the next connection, which starts unactivated — and under a new
// connection number: a router's grant, and answers to requests of the connection that ended, do
// not carry over.
pub fn end[S](mut st S, mut s doip.Server) {
	s.activated = false
	s.fatal = false
	s.buf_len = 0
	s.conn++
	s.ticket++ // an answer still due belongs to the tester that went: no ticket of it matches now
	s.route_open = false
	st.activated(false)
}
