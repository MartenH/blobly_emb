module diag

import comm.isotp
import driver.can

// The channel is a type parameter (a can.Channel on every owner; a fake one in step_test.v) with
// recv / send / tx_ready / tx_idle, as driver/can's.
// The TRANSPORT side of a diagnostic server on its ISO-TP connection — the same for every server,
// the application's (Connection) and the bootloader's (boot.Prog): frame intake, the request a busy
// link drops, the answer pumped onto the channel with a rejected frame aborting it, the S3 hold
// while an exchange is in flight, and the wire drain before a reset. Written once: a serve loop
// that re-implements any of it misses a part (codex #367 r4-r5 found four).

// drain_us bounds the wait for the controller to put a reset's answer on the wire (REQ-BOOT-012):
// a dead bus must not hold the reset off.
pub const drain_us = u64(20_000)

// take_frame feeds one frame of this connection's physical request id to the link — only the bytes
// that arrived (an owner may reuse one frame, so a short one's tail is stale), a frame shorter than
// its PCI says dropped (isotp.Link.truncated). True when it completed a request.
pub fn take_frame(mut l isotp.Link, now u64, f &can.Frame) bool {
	n := if f.len > 8 { 8 } else { int(f.len) } // classic-sized ISO-TP, on CAN-FD too
	if n < 1 || l.truncated(f.data[0], n) {
		return false
	}
	mut p := isotp.Pdu{}
	for i in 0 .. n {
		p.data[i] = f.data[i]
	}
	l.on_frame(now, p)
	return l.has_request()
}

// take_request: the reassembled request into `buf`, its length — or 0. A request that completes
// while an answer is still being sent is DROPPED (ISO-TP is half duplex per connection: the tester
// violated it and retries), and so is one while `blocked` (a reset is pending: the owner is about
// to restart, and an answer now would describe state the restart discards).
pub fn take_request(mut l isotp.Link, buf &u8, blocked bool) int {
	got := l.take(buf)
	return if l.busy() || blocked { 0 } else { got }
}

// next_frame: the next frame of the answer in flight, paced by the peer's flow control. Ask only
// while the channel is ready: the link counts the frame as sent.
pub fn next_frame(mut l isotp.Link, tx_id u32, now u64, mut f can.Frame) bool {
	mut p := isotp.Pdu{}
	if !l.poll(now, mut p) {
		return false
	}
	f.id = tx_id
	f.len = 8
	f.ext = false
	for i in 0 .. 8 {
		f.data[i] = p.data[i]
	}
	return true
}

// pump sends the answer in flight while the channel is ready. A frame the channel REFUSES aborts
// the transfer (the rest could never be reassembled) and returns false: the owner must then treat
// the answer as lost — a reset it announced does not happen (REQ-BOOT-012: never reset unanswered).
pub fn pump[H](mut l isotp.Link, tx_id u32, now u64, mut ch H) bool {
	mut f := can.Frame{}
	for ch.tx_ready() && next_frame(mut l, tx_id, now, mut f) {
		if !ch.send(f) {
			l.abort_tx()
			return false
		}
	}
	return true
}

// in_flight: an exchange is under way on the link — a request arriving or an answer leaving. S3
// does not run meanwhile (ISO 14229-2 starts it once the exchange is over).
pub fn in_flight(l &isotp.Link) bool {
	return !l.idle()
}

// wire_drain waits until the controller has put every handed-off frame on the wire, at most
// drain_us by `clock` — the link going idle only means the last frame reached the Tx FIFO, and an
// immediate reset loses it (REQ-BOOT-012, found on the H755 bench).
pub fn wire_drain[H](mut ch H, clock fn () u64) {
	t0 := clock()
	for !ch.tx_idle() && clock() - t0 < drain_us {}
}

// serve_step is one whole pass of a server that owns its connection and nothing else on its bus —
// the bootloader (boot.Prog). The server answers handle / heard / tick / reset_due / cancel_reset,
// and work_pending / work: routine work it answered responsePending for (a flash erase, a unit at a
// time), whose next step runs once the previous response has left the link AND the wire (a flash
// erase stalls a single-bank chip whole; the drain is bounded by `clock`), its response sent after.
// Returns true when the reset the server answered is due: its answer has left the link — the owner
// then wire_drains and resets.
pub fn serve_step[T, H](mut s T, mut l isotp.Link, rx_id u32, tx_id u32, now u64, mut ch H, req &u8, resp &u8, clock fn () u64) bool {
	l.tick(now)
	mut f := can.Frame{}
	for ch.recv(mut f) {
		if f.id != rx_id || f.ext {
			continue // this connection's physical request id only
		}
		if take_frame(mut l, now, &f) {
			break // one request at a time: the next frame stays queued until this one is served
		}
	}
	n := take_request(mut l, req, s.reset_due())
	if n > 0 {
		s.heard(now) // a request is tester activity (S3, the stay-window)
		rn := s.handle(req, n, resp)
		if rn > 0 && !l.send(resp, rn) {
			s.cancel_reset() // the answer could not be queued: never reset unanswered
		}
	}
	if !pump(mut l, tx_id, now, mut ch) {
		s.cancel_reset()
	}
	// the next step of routine work answered pending, once its previous response is on the wire
	if s.work_pending() && !l.busy() {
		wire_drain(mut ch, clock)
		wn := s.work(now, resp)
		if wn > 0 && (!l.send(resp, wn) || !pump(mut l, tx_id, now, mut ch)) {
			s.cancel_reset()
		}
	}
	if in_flight(&l) {
		s.heard(now) // S3 held while an exchange is in flight
	}
	s.tick(now)
	return s.reset_due() && !l.busy()
}
