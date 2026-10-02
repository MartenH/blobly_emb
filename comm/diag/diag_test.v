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

// a consecutive frame is full unless it carries the last bytes; a truncated final one must not
// complete the request with bytes that never arrived
fn test_a_truncated_final_consecutive_frame_is_dropped() {
	mut c := new_conn()
	mut ff := sf(rx, [u8(0x2E), 0x01, 0x00, 0xAA, 0xBB, 0xCC])
	ff.data[0] = 0x10 // first frame of a 10-byte request: 6 bytes here, 4 to follow
	ff.data[1] = 10
	assert c.on_frame(0, ff) == .taken
	mut fc := can.Frame{}
	assert c.produce(0, mut fc) // our flow control
	mut cf := sf(rx, [u8(0xDD), 0xEE, 0xFF, 0x11])
	cf.data[0] = 0x21
	cf.len = 3 // 2 of the 4 remaining bytes arrived
	assert c.on_frame(1000, cf) == .taken
	assert !c.link.has_request()
	cf.len = 5
	assert c.on_frame(2000, cf) == .request
}

// the owner keeps its network awake while a connection is active
fn test_active_while_an_exchange_or_a_session_is_open() {
	mut c := new_conn()
	assert !c.active()
	c.on_frame(0, sf(rx, [u8(0x10), 0x03]))
	assert c.active() // a request waiting
	c.serve()
	mut f := can.Frame{}
	assert c.produce(0, mut f)
	assert c.active() // the extended session stays open
	c.on_frame(0, sf(rx, [u8(0x10), 0x01]))
	c.serve()
	assert c.produce(0, mut f)
	assert !c.active()
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

// an owner that resets itself is told when the answer has left the link, and the diagnostic state
// is left alone until it does — its reset restarts everything
fn test_an_owner_that_resets_is_told_when_the_answer_has_left() {
	mut c := new_conn()
	c.server.serves_reset = true
	c.owner_resets = true
	mut t := new_tester()
	mut now := u64(0)
	exchange(mut c, mut t, mut &now, [u8(0x10), 0x03])
	c.on_frame(now, sf(rx, [u8(0x11), 0x01]))
	c.serve()
	assert c.reset_due() == 0 // the answer is still in the link
	mut f := can.Frame{}
	assert c.produce(now, mut f)
	assert c.reset_due() == 0x01
	c.housekeep(now)
	assert c.server.session == uds.session_extended // not applied here: the owner resets
	// a suppressed functional reset is due at once, and not applied here either
	mut d := new_conn()
	d.server.serves_reset = true
	d.owner_resets = true
	assert d.on_frame(0, sf(fid, [u8(0x11), 0x81])) == .served
	assert d.reset_due() == 0x01
}

// once a reset is due nothing more is served: the owner is about to restart, and an answer given
// now would describe state the restart discards
fn test_nothing_is_served_once_a_reset_is_due() {
	mut c := new_conn()
	c.server.serves_reset = true
	c.owner_resets = true
	assert c.on_frame(0, sf(fid, [u8(0x11), 0x81])) == .served // suppressed: due at once
	assert c.reset_due() == 0x01
	assert c.on_frame(0, sf(rx, [u8(0x2E), 0x01, 0x00, 0x05])) == .request
	c.serve()
	mut f := can.Frame{}
	assert !c.produce(0, mut f), 'a request was answered while a reset was due'
}

fn remote(mut c Connection, req []u8, functional bool) []u8 {
	mut resp := [isotp.max_payload]u8{}
	n := c.serve_remote(&req[0], req.len, functional, &resp[0])
	return resp[..n].clone()
}

fn test_a_remote_request_is_served_by_the_same_server() {
	mut c := new_conn()
	assert remote(mut c, [u8(0x10), 0x03], false)[0] == 0x50
	assert c.server.session == uds.session_extended // one session, whichever transport opened it
	r := remote(mut c, [u8(0x22), 0xF1, 0x90], false)
	assert r[..3] == [u8(0x62), 0xF1, 0x90]
	assert r[3..].bytestr() == name
	// functional: an unsupported service stays silent
	assert remote(mut c, [u8(0xBA)], true).len == 0
	assert remote(mut c, [u8(0xBA)], false) == [u8(0x7F), 0xBA, 0x11]
}

fn test_a_remote_reset_waits_until_its_transport_has_sent_the_answer() {
	mut c := new_conn()
	c.server.serves_reset = true
	c.owner_resets = true
	assert remote(mut c, [u8(0x11), 0x01], false) == [u8(0x51), 0x01]
	assert c.reset_due() == 0, 'reset before the DoIP answer left'
	assert remote(mut c, [u8(0x3E), 0x00], false).len == 0 // nothing served while a reset is pending
	c.remote_sent()
	assert c.reset_due() == 0x01
	// a suppressed reset has no answer, but DoIP still acks it: due once that is sent
	mut d := new_conn()
	d.server.serves_reset = true
	d.owner_resets = true
	assert remote(mut d, [u8(0x11), 0x81], false).len == 0
	assert d.reset_due() == 0
	d.remote_sent()
	assert d.reset_due() == 0x01
}

// a bus answer that fails mid-transfer cannot cancel a reset the other transport asked for
fn test_a_bus_abort_leaves_a_remote_reset_alone() {
	mut c := new_conn()
	c.server.serves_reset = true
	c.owner_resets = true
	now := u64(0)
	// a multi-frame CAN answer in flight
	c.on_frame(now, sf(rx, [u8(0x22), 0xF1, 0x90]))
	c.serve()
	assert !c.link.idle()
	assert remote(mut c, [u8(0x11), 0x01], false) == [u8(0x51), 0x01]
	c.remote_sent()
	mut f := can.Frame{}
	assert c.produce(now, mut f)
	c.abort_tx()
	assert c.server.reset_req == 0x01, 'the CAN abort cancelled the DoIP reset'
}

fn test_a_dropped_connection_ends_what_it_opened_and_never_resets_unanswered() {
	mut c := new_conn()
	c.server.serves_reset = true
	c.owner_resets = true
	remote(mut c, [u8(0x10), 0x03], false)
	remote(mut c, [u8(0x11), 0x01], false)
	c.remote_dropped()
	assert c.reset_due() == 0, 'reset whose answer never left'
	assert c.server.session == uds.session_default
	// an answered reset survives the tester hanging up right after it
	remote(mut c, [u8(0x11), 0x01], false)
	c.remote_sent()
	c.remote_dropped()
	assert c.reset_due() == 0x01
	c.server.reset_req = 0
	// a bus TesterPresent changes nothing, so the remote tester still owns the session it opened
	mut t := new_tester()
	mut now := u64(0)
	remote(mut c, [u8(0x10), 0x03], false)
	exchange(mut c, mut t, mut &now, [u8(0x3E), 0x00])
	c.on_frame(now, sf(fid, [u8(0x3E), 0x80])) // a functional one neither
	c.remote_dropped()
	assert c.server.session == uds.session_default
	// a bus tester that set the session keeps it; a remote read in between decides nothing
	exchange(mut c, mut t, mut &now, [u8(0x10), 0x03])
	remote(mut c, [u8(0x22), 0xF1, 0x90], false)
	c.remote_dropped()
	assert c.server.session == uds.session_extended
}

fn seed_fixed(ctx voidptr, out &u8, n int) bool {
	for i in 0 .. n {
		unsafe {
			out[i] = u8(0x10 + i)
		}
	}
	return true
}

// unlock level 1 through `ask` (one transport), returning the final 0x27 answer
fn unlock(ask fn ([]u8) []u8) []u8 {
	seed := ask([u8(0x27), 0x01])[2..]
	mut key := [u8(0x27), 0x02]
	for b in seed {
		key << b ^ 0xFF
	}
	return ask(key)
}

// REQ-NET-012: the session is shared, the unlock is the transport's that earned it — a network
// tester never writes under a bus tester's unlock, nor the reverse
fn test_an_unlock_belongs_to_the_transport_that_earned_it() {
	mut c := new_conn()
	c.server.security = uds.SecurityOps{
		seed:   seed_fixed
		key_ok: uds.reference_key_ok
	}
	c.server.security_levels = 0x01
	c.server.dids[2] = uds.Did{
		id:             0x0102
		writable:       true
		len:            1
		write_sessions: uds.in_extended
		write_security: 1
	}
	c.server.ndid = 3
	mut t := new_tester()
	mut now := u64(0)
	mut cc := &c
	over_doip := fn [mut cc] (req []u8) []u8 {
		return remote(mut cc, req, false)
	}
	assert over_doip([u8(0x10), 0x03])[0] == 0x50
	assert unlock(over_doip) == [u8(0x67), 0x02]
	assert over_doip([u8(0x2E), 0x01, 0x02, 0x11]) == [u8(0x6E), 0x01, 0x02]
	// the bus is in the same session but not unlocked
	assert exchange(mut c, mut t, mut &now, [u8(0x2E), 0x01, 0x02, 0x22]) == [u8(0x7F), 0x2E, 0x33]
	// and DoIP's unlock survived the bus request
	assert over_doip([u8(0x2E), 0x01, 0x02, 0x33]) == [u8(0x6E), 0x01, 0x02]
	// the reverse: a bus unlock does not open the network
	seed := exchange(mut c, mut t, mut &now, [u8(0x27), 0x01])[2..]
	mut key := [u8(0x27), 0x02]
	for b in seed {
		key << b ^ 0xFF
	}
	assert exchange(mut c, mut t, mut &now, key) == [u8(0x67), 0x02]
	assert over_doip([u8(0x2E), 0x01, 0x02, 0x44]) == [u8(0x7F), 0x2E, 0x33]
	assert exchange(mut c, mut t, mut &now, [u8(0x2E), 0x01, 0x02, 0x55]) == [u8(0x6E), 0x01, 0x02]
	// a session change over either relocks for both
	assert over_doip([u8(0x10), 0x01])[0] == 0x50
	assert c.server.unlocked == 0
}

fn secured_conn() Connection {
	mut c := new_conn()
	c.server.security = uds.SecurityOps{
		seed:   seed_fixed
		key_ok: uds.reference_key_ok
	}
	c.server.security_levels = 0x01
	c.server.dids[2] = uds.Did{
		id:             0x0102
		writable:       true
		len:            1
		write_sessions: uds.in_extended
		write_security: 1
	}
	c.server.ndid = 3
	return c
}

// a DoIP unlock of the level the bus already holds is still DoIP's, and ends with its connection
fn test_a_dropped_tester_takes_its_unlock_even_at_the_bus_level() {
	mut c := secured_conn()
	mut t := new_tester()
	mut now := u64(0)
	mut cc := &c
	over_doip := fn [mut cc] (req []u8) []u8 {
		return remote(mut cc, req, false)
	}
	exchange(mut c, mut t, mut &now, [u8(0x10), 0x03])
	seed := exchange(mut c, mut t, mut &now, [u8(0x27), 0x01])[2..]
	mut key := [u8(0x27), 0x02]
	for b in seed {
		key << b ^ 0xFF
	}
	assert exchange(mut c, mut t, mut &now, key) == [u8(0x67), 0x02]
	assert unlock(over_doip) == [u8(0x67), 0x02] // same level, now DoIP's
	c.remote_dropped()
	assert over_doip([u8(0x2E), 0x01, 0x02, 0x11]) == [u8(0x7F), 0x2E, 0x33], 'the next connection inherited the unlock'
}

// a seed asked over one transport does not replace the challenge the other is answering
fn test_seed_key_exchanges_are_per_transport() {
	mut c := secured_conn()
	mut t := new_tester()
	mut now := u64(0)
	mut cc := &c
	over_doip := fn [mut cc] (req []u8) []u8 {
		return remote(mut cc, req, false)
	}
	exchange(mut c, mut t, mut &now, [u8(0x10), 0x03])
	can_seed := exchange(mut c, mut t, mut &now, [u8(0x27), 0x01])[2..]
	assert over_doip([u8(0x27), 0x01])[0] == 0x67 // DoIP asks for its own seed in between
	mut key := [u8(0x27), 0x02]
	for b in can_seed {
		key << b ^ 0xFF
	}
	assert exchange(mut c, mut t, mut &now, key) == [u8(0x67), 0x02], 'the CAN challenge was replaced'
}

// re-entering the session the bus is in, over the other transport, voids the bus's challenge
fn test_a_session_reentry_voids_an_outstanding_seed() {
	mut c := secured_conn()
	mut t := new_tester()
	mut now := u64(0)
	exchange(mut c, mut t, mut &now, [u8(0x10), 0x03])
	can_seed := exchange(mut c, mut t, mut &now, [u8(0x27), 0x01])[2..]
	assert remote(mut c, [u8(0x10), 0x03], false)[0] == 0x50 // same session, a new entry
	mut key := [u8(0x27), 0x02]
	for b in can_seed {
		key << b ^ 0xFF
	}
	assert exchange(mut c, mut t, mut &now, key) == [u8(0x7F), 0x27, 0x24], 'a key for a void seed'
	assert c.server.unlocked == 0	// and a bus unlock is not handed back after the other transport re-entered the session
	seed2 := exchange(mut c, mut t, mut &now, [u8(0x27), 0x01])[2..]
	mut key2 := [u8(0x27), 0x02]
	for b in seed2 {
		key2 << b ^ 0xFF
	}
	assert exchange(mut c, mut t, mut &now, key2) == [u8(0x67), 0x02]
	remote(mut c, [u8(0x10), 0x03], false)
	assert exchange(mut c, mut t, mut &now, [u8(0x2E), 0x01, 0x02, 0x11]) == [u8(0x7F), 0x2E, 0x33]
}

// The cross-transport security rule as a model, checked over random interleavings: the session is
// shared; an unlock belongs to the transport that ran the exchange; a seed is void after ANY session
// entry; a dropped remote tester ends its unlock and its exchange, and the session too if it entered
// it last; a reset asked over either transport either happens (power-on) or, its answer lost, is
// cancelled and changes nothing (a DoIP drop in between still ends what DoIP held). Each step's
// answer, the session and who holds the unlock must be the model's. 100,000 steps: the rarest path
// (a bus reset cancelled while DoIP holds the unlock) comes up a handful of times.
// ask_over: one request over the bus (0) or the other transport (1), whose answer it then sends
fn ask_over(tr int, mut c Connection, mut t isotp.Link, mut now &u64, req []u8) []u8 {
	if tr == 1 {
		r := remote(mut c, req, false)
		c.remote_sent()
		return r
	}
	return exchange(mut c, mut t, mut now, req)
}

struct SecModel {
mut:
	session     u8 = 0x01
	epoch       int
	unlocked    [2]bool
	pending     [2]int = [-1, -1]!
	remote_owns bool
}

fn (mut m SecModel) enter(sess u8, remote bool) {
	m.session = sess
	m.epoch++
	m.unlocked = [false, false]!
	m.remote_owns = remote
}

fn test_the_cross_transport_security_model_holds_over_random_interleavings() {
	mut c := secured_conn()
	c.server.s3_us = u64(1) << 60 // no S3 in this model
	c.server.serves_reset = true // the host shape: an answered reset returns the server to power-on
	mut t := new_tester()
	mut now := u64(0)
	mut m := SecModel{}
	mut rng := u32(0x2545F491)
	for step in 0 .. 100000 {
		rng ^= rng << 13
		rng ^= rng >> 17
		rng ^= rng << 5
		tr := int(rng & 1) // 0 = bus, 1 = remote
		op := (rng >> 1) % 11
		ctx := 'step ${step} op ${op} over ${if tr == 1 { 'remote' } else { 'bus' }}'
		match op {
			0, 1 {
				sess := if op == 0 { u8(0x03) } else { u8(0x01) }
				assert ask_over(tr, mut c, mut t, mut &now, [u8(0x10), sess])[0] == 0x50, ctx
				m.enter(sess, tr == 1)
			}
			2 {
				if m.session != 0x03 || m.unlocked[tr] {
					continue
				}
				sr := ask_over(tr, mut c, mut t, mut &now, [u8(0x27), 0x01])
				assert sr[0] == 0x67, '${ctx}: ${sr} model ${m}'
				m.pending[tr] = m.epoch
			}
			3 {
				if m.session != 0x03 {
					continue
				}
				mut key := [u8(0x27), 0x02]
				for i in 0 .. uds.seed_len {
					key << u8(0x10 + i) ^ 0xFF
				}
				r := ask_over(tr, mut c, mut t, mut &now, key)
				if m.pending[tr] == m.epoch {
					assert r == [u8(0x67), 0x02], ctx
					m.unlocked[tr] = true
					m.unlocked[1 - tr] = false
				} else {
					assert r == [u8(0x7F), 0x27, 0x24], '${ctx}: a key for a void seed: ${r}'
				}
				m.pending[tr] = -1
			}
			4 {
				r := ask_over(tr, mut c, mut t, mut &now, [u8(0x2E), 0x01, 0x02, u8(step)])
				ok := m.session == 0x03 && m.unlocked[tr]
				assert (r[0] == 0x6E) == ok, '${ctx}: write ${r} where the model says ${ok}'
			}
			5 {
				c.remote_dropped()
				if m.remote_owns {
					m.enter(0x01, false)
				}
				m.unlocked[1] = false
				m.pending[1] = -1
			}
			8, 9, 10 {
				// a reset asked over the bus: its answer sent (8: it happens), or lost (9: cancelled),
				// or lost after a DoIP drop in between (10)
				assert c.on_frame(now, sf(rx, [u8(0x11), 0x01])) == .request, ctx
				c.serve()
				if op == 10 {
					c.remote_dropped()
					if m.remote_owns {
						m.enter(0x01, false)
					}
					m.unlocked[1] = false
					m.pending[1] = -1
				}
				mut f := can.Frame{}
				assert c.produce(now, mut f), ctx
				if op == 8 {
					c.housekeep(now)
					m.enter(0x01, false)
					m.pending = [-1, -1]!
				} else {
					c.abort_tx()
				}
			}
			else {
				// a reset asked over DoIP: its answer sent (the reset happens), or the connection lost
				// first (cancelled — what its request hid comes back, the dropped tester's own does not)
				assert remote(mut c, [u8(0x11), 0x01], false) == [u8(0x51), 0x01], ctx
				if op == 6 {
					c.remote_sent()
					c.housekeep(now)
					m.enter(0x01, false)
					m.pending = [-1, -1]!
				} else {
					c.remote_dropped()
					if m.remote_owns {
						m.enter(0x01, false)
					}
					m.unlocked[1] = false
					m.pending[1] = -1
				}
			}
		}
		assert c.server.session == m.session, '${ctx}: session ${c.server.session} model ${m}'
		// and who holds the unlock, directly — not only when a later write happens to ask
		for x in 0 .. 2 {
			holds := c.server.unlocked != 0 && c.unlock_remote == (x == 1)
			assert holds == m.unlocked[x], '${ctx}: transport ${x} unlocked ${holds}, model ${m}'
		}
	}
}

// a reset asked over one transport, then cancelled (its answer lost), gives the other its unlock back
fn test_a_cancelled_reset_restores_the_hidden_unlock() {
	mut c := secured_conn()
	c.server.serves_reset = true
	c.owner_resets = true
	mut t := new_tester()
	mut now := u64(0)
	exchange(mut c, mut t, mut &now, [u8(0x10), 0x03])
	seed := exchange(mut c, mut t, mut &now, [u8(0x27), 0x01])[2..]
	mut key := [u8(0x27), 0x02]
	for b in seed {
		key << b ^ 0xFF
	}
	assert exchange(mut c, mut t, mut &now, key) == [u8(0x67), 0x02]
	assert remote(mut c, [u8(0x11), 0x01], false) == [u8(0x51), 0x01]
	c.remote_dropped() // the DoIP answer never left: the reset is cancelled
	assert c.reset_due() == 0
	assert exchange(mut c, mut t, mut &now, [u8(0x2E), 0x01, 0x02, 0x11]) == [u8(0x6E), 0x01, 0x02], 'the bus lost its unlock to a cancelled reset'
}

// a DoIP unlock hidden by a bus reset request does not come back as the bus's after DoIP drops
fn test_a_dropped_testers_hidden_unlock_is_not_handed_to_the_bus() {
	mut c := secured_conn()
	c.server.serves_reset = true
	c.owner_resets = true
	mut t := new_tester()
	mut now := u64(0)
	mut cc := &c
	over_doip := fn [mut cc] (req []u8) []u8 {
		return remote(mut cc, req, false)
	}
	over_doip([u8(0x10), 0x03])
	assert unlock(over_doip) == [u8(0x67), 0x02]
	c.on_frame(now, sf(rx, [u8(0x11), 0x01]))
	c.serve() // the bus asks for a reset: DoIP's unlock held back
	c.remote_dropped()
	mut f := can.Frame{}
	assert c.produce(now, mut f)
	c.abort_tx() // the bus answer is lost: the reset is cancelled
	assert c.server.unlocked == 0, 'the unlock of the dropped tester came back'
	assert exchange(mut c, mut t, mut &now, [u8(0x2E), 0x01, 0x02, 0x11])[..2] == [u8(0x7F), 0x2E]
}

// an answered DoIP request still on its way holds a reset the bus asked for in the same pass
fn test_a_bus_reset_waits_for_a_doip_answer_in_flight() {
	mut c := new_conn()
	c.server.serves_reset = true
	c.owner_resets = true
	assert remote(mut c, [u8(0x22), 0xF1, 0x90], false)[0] == 0x62 // answered, not yet sent
	assert c.on_frame(0, sf(rx, [u8(0x11), 0x01])) == .request
	c.serve()
	mut f := can.Frame{}
	assert c.produce(0, mut f)
	assert c.reset_due() == 0, 'the reset overtook the DoIP answer'
	c.remote_sent()
	assert c.reset_due() == 0x01
}

// S3 does not run while a DoIP answer is still on its way, as it does not while ISO-TP is busy
fn test_s3_holds_while_a_remote_answer_is_in_flight() {
	mut c := new_conn()
	c.server.s3_us = 1000
	c.housekeep(0)
	assert remote(mut c, [u8(0x10), 0x03], false)[0] == 0x50
	c.housekeep(5000) // the answer not yet sent: no timeout
	assert c.server.session == uds.session_extended
	c.remote_sent()
	c.housekeep(5500)
	assert c.server.session == uds.session_extended
	c.housekeep(7000)
	assert c.server.session == uds.session_default
}
