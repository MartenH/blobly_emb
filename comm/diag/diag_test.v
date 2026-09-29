module diag

// @verifies REQ-DIAG-001 REQ-DIAG-002 REQ-DIAG-003 REQ-DIAG-006 REQ-DIAG-007
import comm.isotp
import comm.uds
import driver.can

const rx = u32(0x7b0)
const tx = u32(0x7b8)
const fid = u32(0x7df)
const name = 'BLOBLY-DOMAIN-0001'

fn new_conn() Connection {
	mut c := Connection{}
	c.init(rx, tx, fid, 0, 0)
	c.server.dids[0] = uds.Did{
		id: 0xF190
	}
	for i, b in name.bytes() {
		c.server.dids[0].data[i] = b
	}
	c.server.dids[0].len = u8(name.len)
	c.server.dids[1] = uds.Did{
		id: 0xF1A0
	}
	c.server.ndid = 2
	return c
}

fn new_tester() isotp.Link {
	mut t := isotp.Link{}
	t.init_defaults()
	return t
}

fn frame_of(id u32, p isotp.Pdu) &can.Frame {
	mut f := &can.Frame{
		id:  id
		len: 8
	}
	for i in 0 .. 8 {
		f.data[i] = p.data[i]
	}
	return f
}

fn pdu_of(f can.Frame) isotp.Pdu {
	mut p := isotp.Pdu{}
	for i in 0 .. 8 {
		p.data[i] = f.data[i]
	}
	return p
}

// single frame on `id`, as a tester puts one on the wire
fn sf(id u32, req []u8) &can.Frame {
	mut f := &can.Frame{
		id:  id
		len: 8
	}
	f.data[0] = u8(req.len)
	for i, b in req {
		f.data[1 + i] = b
	}
	return f
}

// pass runs one owner pass in the documented order: the tester's frames are the drain.
fn pass(mut c Connection, now u64, mut t isotp.Link) {
	c.housekeep(now)
	mut p := isotp.Pdu{}
	for t.poll(now, mut p) {
		if c.on_frame(now, frame_of(rx, p)) == .request {
			break
		}
	}
	c.serve()
	mut f := can.Frame{}
	for c.produce(now, mut f) {
		assert f.id == tx
		t.on_frame(now, pdu_of(f))
	}
}

// exchange sends `req` from the tester and runs passes until its answer is reassembled.
fn exchange(mut c Connection, mut t isotp.Link, mut now &u64, req []u8) []u8 {
	assert t.send(&req[0], req.len)
	for _ in 0 .. 50 {
		unsafe {
			*now += 1000
		}
		pass(mut c, *now, mut t)
		if t.has_request() {
			mut buf := []u8{len: isotp.max_payload}
			n := t.take(unsafe { &buf[0] })
			return buf[..n]
		}
	}
	assert false, 'no answer to ${req}'
	return []u8{}
}

fn test_a_physical_request_is_answered_on_the_response_id() {
	mut c := new_conn()
	mut t := new_tester()
	mut now := u64(0)
	assert exchange(mut c, mut t, mut &now, [u8(0x3E), 0x00]) == [u8(0x7E), 0x00]
}

fn test_a_multi_frame_answer_follows_the_testers_flow_control() {
	mut c := new_conn()
	mut t := new_tester()
	mut now := u64(0)
	mut want := [u8(0x62), 0xF1, 0x90]
	want << name.bytes()
	assert exchange(mut c, mut t, mut &now, [u8(0x22), 0xF1, 0x90]) == want
}

fn test_a_live_did_is_refreshed_before_every_dispatch() {
	mut c := new_conn()
	mut t := new_tester()
	mut now := u64(0)
	c.refresh = fn (mut s uds.Server) {
		s.dids[1].data[0] = 0x42
		s.dids[1].len = 1
	}
	assert exchange(mut c, mut t, mut &now, [u8(0x22), 0xF1, 0xA0]) == [u8(0x62), 0xF1, 0xA0, 0x42]
	f := sf(fid, [u8(0x22), 0xF1, 0xA0])
	c.server.dids[1].data[0] = 0
	assert c.on_frame(now, f) == .served
	mut out := can.Frame{}
	assert c.produce(now, mut out)
	assert out.data[..5] == [u8(0x04), 0x62, 0xF1, 0xA0, 0x42]
}

fn test_a_functional_request_is_served_on_arrival_and_dropped_while_busy() {
	mut c := new_conn()
	mut out := can.Frame{}
	assert c.on_frame(0, sf(fid, [u8(0x3E), 0x00])) == .served
	assert c.produce(0, mut out)
	assert out.id == tx && out.data[..3] == [u8(0x02), 0x7E, 0x00]
	// a suppressed positive response is served and says nothing
	assert c.on_frame(0, sf(fid, [u8(0x3E), 0x80])) == .served
	assert !c.produce(0, mut out)
	// an answer still queued: the link is not quiet, so the functional request is dropped
	assert c.on_frame(0, sf(fid, [u8(0x3E), 0x00])) == .served
	assert c.on_frame(0, sf(fid, [u8(0x3E), 0x00])) == .taken
}

fn test_a_request_completing_while_an_answer_is_in_flight_is_dropped() {
	mut c := new_conn()
	mut t := new_tester()
	// the multi-frame answer starts: its first frame is out, the rest waits for flow control
	c.on_frame(0, sf(rx, [u8(0x22), 0xF1, 0x90]))
	c.serve()
	mut ff := can.Frame{}
	assert c.produce(0, mut ff)
	assert ff.data[0] >> 4 == 1
	// a second request completes meanwhile: taken out of the link and discarded
	assert c.on_frame(0, sf(rx, [u8(0x3E), 0x00])) == .request
	c.serve()
	t.on_frame(0, pdu_of(ff))
	mut now := u64(0)
	for _ in 0 .. 10 {
		now += 1000
		pass(mut c, now, mut t)
	}
	mut buf := []u8{len: isotp.max_payload}
	n := t.take(unsafe { &buf[0] })
	assert buf[..3] == [u8(0x62), 0xF1, 0x90] && n == 3 + name.len
	// and it is never answered later
	for _ in 0 .. 10 {
		now += 1000
		pass(mut c, now, mut t)
	}
	assert !t.has_request()
}

fn test_a_reset_waits_for_its_answer_and_a_lost_answer_cancels_it() {
	mut c := new_conn()
	c.server.serves_reset = true
	mut t := new_tester()
	mut now := u64(0)
	exchange(mut c, mut t, mut &now, [u8(0x10), 0x03])
	assert c.server.session == uds.session_extended
	c.on_frame(now, sf(rx, [u8(0x11), 0x01]))
	c.serve()
	c.housekeep(now) // the answer has not left: the extended session stands
	assert c.server.session == uds.session_extended
	mut f := can.Frame{}
	assert c.produce(now, mut f)
	assert f.data[..3] == [u8(0x02), 0x51, 0x01]
	c.housekeep(now)
	assert c.server.session == uds.session_default
	// the channel refuses the answer: the reset is abandoned with it
	exchange(mut c, mut t, mut &now, [u8(0x10), 0x03])
	c.on_frame(now, sf(rx, [u8(0x11), 0x01]))
	c.serve()
	assert c.produce(now, mut f)
	c.abort_tx()
	c.housekeep(now)
	assert c.server.session == uds.session_extended
}

fn test_a_suppressed_functional_reset_applies_before_the_next_frame() {
	mut c := new_conn()
	c.server.serves_reset = true
	mut t := new_tester()
	mut now := u64(0)
	exchange(mut c, mut t, mut &now, [u8(0x10), 0x03])
	assert c.on_frame(now, sf(fid, [u8(0x11), 0x81])) == .served
	assert c.server.session == uds.session_default
}

fn test_s3_does_not_run_while_the_link_is_busy() {
	mut c := new_conn()
	c.server.s3_us = 5000
	mut t := new_tester()
	mut now := u64(0)
	exchange(mut c, mut t, mut &now, [u8(0x10), 0x03])
	// a multi-frame answer whose flow control never comes: the link stays busy past S3
	c.on_frame(now, sf(rx, [u8(0x22), 0xF1, 0x90]))
	c.serve()
	mut f := can.Frame{}
	assert c.produce(now, mut f)
	c.housekeep(now + 20_000)
	assert c.server.session == uds.session_extended
	// once the link goes quiet, S3 runs from the last pass that saw it busy
	c.abort_tx()
	c.housekeep(now + 24_000)
	assert c.server.session == uds.session_extended
	c.housekeep(now + 26_000)
	assert c.server.session == uds.session_default
}

// housekeep expires the link BEFORE it asks whether the link is busy: a transfer that dies in this
// pass does not hold S3 for it
fn test_a_link_expiring_in_the_pass_does_not_hold_s3() {
	mut c := new_conn()
	c.server.s3_us = 5000
	mut t := new_tester()
	mut now := u64(0)
	exchange(mut c, mut t, mut &now, [u8(0x10), 0x03])
	c.link.n_bs_us = 10_000
	c.on_frame(now, sf(rx, [u8(0x22), 0xF1, 0x90]))
	c.serve()
	mut f := can.Frame{}
	assert c.produce(now, mut f) // first frame out; flow control never comes
	c.housekeep(now + 8000) // still waiting: S3 held
	assert c.server.session == uds.session_extended
	c.housekeep(now + 16_000) // N_Bs expires in this pass: S3 runs from the last hold
	assert c.link.idle()
	assert c.server.session == uds.session_default
}

fn test_frames_that_are_not_this_connections_are_left_alone() {
	mut c := new_conn()
	mut ext := sf(rx, [u8(0x3E), 0x00])
	ext.ext = true
	assert c.on_frame(0, ext) == .other
	assert c.on_frame(0, sf(0x123, [u8(0x3E), 0x00])) == .other
	// a first frame on the functional id is this connection's, and no request: dropped
	mut ff := sf(fid, [u8(0x3E), 0x00])
	ff.data[0] = 0x10
	assert c.on_frame(0, ff) == .taken
}

// an owner that may not transmit abandons both directions: a first frame received meanwhile owes a
// flow control that must never go out late, and N_Cr cannot expire a reception it never armed
fn test_abandon_drops_a_reception_and_its_owed_flow_control() {
	mut c := new_conn()
	mut ff := sf(rx, [u8(0x2E), 0x01, 0x00])
	ff.data[0] = 0x10 // first frame of a 20-byte request
	ff.data[1] = 20
	assert c.on_frame(0, ff) == .taken
	assert !c.link.idle()
	c.abandon()
	assert c.link.idle()
	mut f := can.Frame{}
	assert !c.produce(1000, mut f), 'a stale flow control went out after the abandon'
	// the link takes the next request as new
	assert c.on_frame(2000, sf(rx, [u8(0x3E), 0x00])) == .request
}

// a short frame's tail is whatever the owner's reused frame held last: never read as request bytes
fn test_a_short_physical_frame_is_never_read_past_its_length() {
	mut c := new_conn()
	mut stale := sf(rx, [u8(0x10), 0x03])
	stale.len = 2 // PCI claims 2 bytes, only 1 arrived: the 0x03 is a leftover
	assert c.on_frame(0, stale) == .taken
	assert !c.link.has_request()
	mut short_ff := sf(rx, [u8(0x2E), 0x01, 0x00])
	short_ff.data[0] = 0x10
	short_ff.data[1] = 20
	short_ff.len = 5
	assert c.on_frame(0, short_ff) == .taken
	assert c.link.idle()
	// a single frame of exactly its length is a request
	mut exact := sf(rx, [u8(0x3E), 0x00])
	exact.len = 3
	assert c.on_frame(0, exact) == .request
}
