module diag

// @verifies REQ-DIAG-083 REQ-DIAG-084 REQ-DIAG-085
// An owed answer (comm/uds pending.v) on its connection: responsePending as single frames on the
// bus, the final answer segmented; over the other transport pushed, each once the one before it
// was acknowledged; the transport that owes it never moved by a request dropped over the other;
// S3 held while a pushed answer is unacknowledged; a dropped connection abandoning only what it was
// owed; a timeout bounded whatever the transport does.
import comm.isotp
import comm.uds
import driver.can

const r_rx = u32(0x7C0)
const r_tx = u32(0x7C8)
const r_fid = u32(0x7DF)
const r_t0 = u64(1_000_000)

const owed_78 = [u8(0x7F), 0x31, 0x78]

// routines: 0x0201 sync with a 20-byte start record, 0x0202 async with stop and a 32-byte results
// record, 0x0203 sync with a 2-byte start record (a DoIP push holds it) — every session, no level
fn rconn() Connection {
	mut c := Connection{}
	req := []u8{len: 520}
	resp := []u8{len: 520}
	c.init(r_rx, r_tx, r_fid, 0, 0, &req[0], &resp[0], 520)
	c.server.routines[0] = uds.Routine{
		id:         0x0201
		start_in:   1
		start_out:  20
		timeout_us: 10_000_000
	}
	c.server.routines[1] = uds.Routine{
		id:          0x0202
		async:       true
		stop:        true
		results:     true
		results_out: 32
		timeout_us:  10_000_000
	}
	c.server.routines[2] = uds.Routine{
		id:         0x0203
		start_in:   1
		start_out:  2
		timeout_us: 10_000_000
	}
	c.server.nroutines = 3
	c.server.s3_us = 2_000_000
	return c
}

fn tsend(mut t isotp.Link, req []u8) {
	assert t.send(&req[0], req.len)
}

fn rtester() isotp.Link {
	mut t := isotp.Link{}
	t.init_defaults()
	rxb := []u8{len: isotp.message_limit}
	txb := []u8{len: isotp.message_limit}
	t.bind_rx(&rxb[0], isotp.message_limit)
	t.bind_tx(&txb[0], isotp.message_limit)
	return t
}

// Bus is what one pass put on the bus: its frames, and the answers the tester reassembled
struct Bus {
mut:
	frames  []can.Frame
	answers [][]u8
}

// Wire is the channel an owner pumps into (Connection.pump, as the generated owners call it): what
// it takes is recorded; while `refuse` it takes nothing (a refused frame)
struct Wire {
mut:
	tx     []can.Frame
	refuse bool
}

fn (mut w Wire) tx_ready() bool {
	return true
}

fn (mut w Wire) send(f can.Frame) bool {
	if w.refuse {
		return false
	}
	w.tx << f
	return true
}

// bus_pass runs one owner pass as the generated owners do — housekeep, the drain, serve, then pump
// (the owed answer's step first, then the frames) — and hands every frame to the tester; with
// `refuse`, the channel refuses every frame of the pass
fn bus_pass(mut c Connection, now u64, mut t isotp.Link, mut b Bus) {
	bus_pass_on(mut c, now, mut t, mut b, false)
}

fn bus_pass_on(mut c Connection, now u64, mut t isotp.Link, mut b Bus, refuse bool) {
	c.housekeep(now)
	mut p := isotp.Pdu{}
	for t.poll(now, mut p) {
		mut f := &can.Frame{
			id:  r_rx
			len: 8
		}
		for i in 0 .. 8 {
			f.data[i] = p.data[i]
		}
		if c.on_frame(now, f) == .request {
			break
		}
	}
	c.serve()
	mut w := Wire{
		refuse: refuse
	}
	c.pump(now, mut w)
	for f in w.tx {
		b.frames << f
		mut q := isotp.Pdu{}
		for i in 0 .. 8 {
			q.data[i] = f.data[i]
		}
		t.on_frame(now, q)
	}
	if t.has_request() {
		mut buf := []u8{len: isotp.message_limit}
		n := t.take(unsafe { &buf[0] })
		b.answers << buf[..n]
	}
}

// passes runs `n` passes 1 ms apart from `now`, gathering what they put on the bus
fn passes(mut c Connection, mut now &u64, mut t isotp.Link, n int) Bus {
	mut b := Bus{}
	for _ in 0 .. n {
		unsafe {
			*now += 1000
		}
		bus_pass(mut c, *now, mut t, mut b)
	}
	return b
}

// FbSim plays routine i's FB through its cells, as the generated glue does
struct FbSim {
mut:
	f uds.RoutineFb
}

fn (mut fb FbSim) run(mut c Connection, i int, state uds.RoutineState, rec []u8) uds.RoutineOp {
	op := fb.f.take(&c.server.routines[i].req)
	if fb.f.report(state, 0) {
		for k in 0 .. uds.max_routine_record {
			fb.f.res.data[k] = if k < rec.len { rec[k] } else { u8(0) }
		}
	}
	c.server.routines[i].res = fb.f.res
	return op
}

fn remote(mut c Connection, req []u8) []u8 {
	resp := []u8{len: 520}
	n := c.serve_remote(&req[0], req.len, false, &resp[0])
	return resp[..n]
}

fn push(mut c Connection) []u8 {
	mut out := [16]u8{}
	n := c.push_step(&out[0], out.len)
	mut r := []u8{}
	for i in 0 .. n {
		r << out[i]
	}
	return r
}

fn record(n int) []u8 {
	mut r := []u8{}
	for i in 0 .. n {
		r << u8(i + 1)
	}
	return r
}

// On the bus: the request's own 0x78 a single frame, the next only 4 s later, the final answer
// segmented; a frame the channel refuses sends the 0x78 again in the next pass; the connection is
// active (NM held) while an answer is owed, even in the default session.
fn test_a_bus_owed_answer() {
	mut c := rconn()
	mut t := rtester()
	mut fb := FbSim{}
	mut now := r_t0
	tsend(mut t, [u8(0x31), 0x01, 0x02, 0x01, 0x05])
	mut b := passes(mut c, mut &now, mut t, 3)
	assert b.answers == [owed_78]
	assert b.frames.len == 1 && b.frames[0].data[0] == 0x03, 'a responsePending is one single frame'
	assert c.server.session == uds.session_default && c.active()
	fb.run(mut c, 0, .running, [])
	start := now
	for now < start + uds.pending_repeat_us - 5000 {
		b = passes(mut c, mut &now, mut t, 1)
		assert b.frames.len == 0
	}
	b = passes(mut c, mut &now, mut t, 10)
	assert b.answers == [owed_78]
	// a 0x78 the channel refuses: aborted, and sent again in the next pass
	now += uds.pending_repeat_us
	b = Bus{}
	bus_pass_on(mut c, now, mut t, mut b, true)
	assert b.frames.len == 0
	b = passes(mut c, mut &now, mut t, 1)
	assert b.answers == [owed_78]
	// the final answer, segmented: a 20-byte record
	fb.run(mut c, 0, .done, record(20))
	b = passes(mut c, mut &now, mut t, 10)
	mut want := [u8(0x71), 0x01, 0x02, 0x01, uds.routine_info_done]
	want << record(20)
	assert b.answers == [want]
	assert b.frames.len > 1 && b.frames[0].data[0] >> 4 == 1, 'the final answer is multi-frame'
	assert !c.server.pending()
	// 03 answers a 32-byte record, segmented too
	tsend(mut t, [u8(0x31), 0x01, 0x02, 0x02])
	passes(mut c, mut &now, mut t, 3)
	fb.run(mut c, 1, .running, record(32))
	assert passes(mut c, mut &now, mut t, 3).answers == [[u8(0x71), 0x01, 0x02, 0x02, 0x01]]
	tsend(mut t, [u8(0x31), 0x03, 0x02, 0x02])
	mut res := [u8(0x71), 0x03, 0x02, 0x02, 0x01]
	res << record(32)
	assert passes(mut c, mut &now, mut t, 10).answers == [res]
}

// An answer owed over the other transport stays there: a bus request is dropped meanwhile and the
// responses go by push_step only, each once the one before it was acknowledged; and the reverse.
fn test_the_owing_transport_is_never_moved_by_a_dropped_request() {
	mut c := rconn()
	mut t := rtester()
	mut fb := FbSim{}
	mut now := r_t0
	c.housekeep(now)
	// nothing is pushed before the request's own 0x78 is acknowledged — not the final answer, ready
	// at once, nor a 0x78 come due
	assert remote(mut c, [u8(0x31), 0x01, 0x02, 0x03, 0x01]) == owed_78
	fb.run(mut c, 2, .done, [u8(0xAA), 0xBB])
	assert push(mut c).len == 0, 'its own answer is not acknowledged yet'
	now += uds.pending_repeat_us
	c.housekeep(now)
	assert push(mut c).len == 0, 'its own answer is not acknowledged yet, a 0x78 due'
	c.remote_sent()
	assert push(mut c) == [u8(0x71), 0x01, 0x02, 0x03, 0x02, 0xAA, 0xBB]
	c.pushed(true)
	c.push_sent()
	// and every one after it once the one before it was acknowledged
	assert remote(mut c, [u8(0x31), 0x01, 0x02, 0x03, 0x01]) == owed_78
	c.remote_sent()
	fb.run(mut c, 2, .running, [])
	tsend(mut t, [u8(0x3E), 0x00])
	mut b := passes(mut c, mut &now, mut t, 5)
	assert b.frames.len == 0, 'a dropped bus request is answered, or the owed answer went on the bus'
	now += uds.pending_repeat_us
	b = passes(mut c, mut &now, mut t, 1)
	assert b.frames.len == 0
	assert push(mut c) == owed_78
	c.pushed(true)
	fb.run(mut c, 2, .done, [u8(0xAA), 0xBB])
	assert push(mut c).len == 0, 'the push before it is not acknowledged yet'
	c.push_sent()
	assert passes(mut c, mut &now, mut t, 3).frames.len == 0
	assert push(mut c) == [u8(0x71), 0x01, 0x02, 0x03, 0x02, 0xAA, 0xBB]
	c.pushed(true)
	c.push_sent()
	// a push the transport refused: the next responsePending at once
	assert remote(mut c, [u8(0x31), 0x01, 0x02, 0x03, 0x01]) == owed_78
	c.remote_sent()
	fb.run(mut c, 2, .running, [])
	now += uds.pending_repeat_us
	passes(mut c, mut &now, mut t, 1)
	assert push(mut c) == owed_78
	c.pushed(false)
	assert push(mut c) == owed_78
	c.pushed(true)
	c.push_sent()
	fb.run(mut c, 2, .done, [])
	assert push(mut c)[0] == 0x71
	c.pushed(true)
	c.push_sent()
	// the reverse: owed on the bus, a remote request dropped, the answer still on the bus
	tsend(mut t, [u8(0x31), 0x01, 0x02, 0x03, 0x01])
	assert passes(mut c, mut &now, mut t, 3).answers == [owed_78]
	assert remote(mut c, [u8(0x22), 0xF1, 0x90]).len == 0
	c.remote_sent()
	fb.run(mut c, 2, .done, [u8(1), 2])
	assert push(mut c).len == 0
	assert passes(mut c, mut &now, mut t, 3).answers == [[u8(0x71), 0x01, 0x02, 0x03, 0x02, 1, 2]]
}

// S3 does not run while a pushed answer awaits its acknowledgement; once acknowledged it does.
fn test_s3_is_held_until_a_pushed_answer_is_acknowledged() {
	mut c := rconn()
	mut t := rtester()
	mut fb := FbSim{}
	mut now := r_t0
	c.housekeep(now)
	assert remote(mut c, [u8(0x10), 0x03])[0] == 0x50
	c.remote_sent()
	assert remote(mut c, [u8(0x31), 0x01, 0x02, 0x03, 0x01]) == owed_78
	c.remote_sent()
	fb.run(mut c, 2, .done, [])
	assert push(mut c)[0] == 0x71
	c.pushed(true)
	passes(mut c, mut &now, mut t, 9000) // 9 s, the push unacknowledged
	assert c.server.session == uds.session_extended
	c.push_sent()
	passes(mut c, mut &now, mut t, 2100)
	assert c.server.session == uds.session_default
}

// A connection dropped while a pushed response awaits its acknowledgement: the push is forgotten
// with it, so S3 runs again and the next answer owed over DoIP is pushed.
fn test_a_dropped_connection_forgets_its_unacknowledged_push() {
	mut c := rconn()
	mut t := rtester()
	mut fb := FbSim{}
	mut now := r_t0
	c.housekeep(now)
	assert remote(mut c, [u8(0x10), 0x03])[0] == 0x50
	c.remote_sent()
	assert remote(mut c, [u8(0x31), 0x01, 0x02, 0x03, 0x01]) == owed_78
	c.remote_sent()
	fb.run(mut c, 2, .running, [])
	now += uds.pending_repeat_us
	passes(mut c, mut &now, mut t, 1)
	assert push(mut c) == owed_78
	c.pushed(true) // and never acknowledged: the connection drops
	c.remote_dropped()
	assert !c.server.pending()
	assert c.server.session == uds.session_default, 'its session ended with it'
	// a new connection's session, and an answer owed to it
	assert remote(mut c, [u8(0x10), 0x03])[0] == 0x50
	c.remote_sent()
	passes(mut c, mut &now, mut t, 2100)
	assert c.server.session == uds.session_default, 'S3 held by a push the dropped connection left'
	assert remote(mut c, [u8(0x10), 0x03])[0] == 0x50
	c.remote_sent()
	assert remote(mut c, [u8(0x31), 0x01, 0x02, 0x03, 0x01]) == owed_78
	c.remote_sent()
	fb.run(mut c, 2, .stopped, []) // the stop the drop asked
	fb.run(mut c, 2, .done, [u8(1), 2])
	assert push(mut c) == [u8(0x71), 0x01, 0x02, 0x03, 0x02, 1, 2], 'a push left outstanding by the dropped connection'
}

// A dropped connection abandons the answer owed to it and asks the FB to stop; an answer owed to
// the bus in a session that connection opened is answered 0x22 on the bus instead.
fn test_a_dropped_connection_abandons_only_its_own_answer() {
	mut c := rconn()
	mut t := rtester()
	mut fb := FbSim{}
	mut now := r_t0
	c.housekeep(now)
	assert remote(mut c, [u8(0x31), 0x01, 0x02, 0x03, 0x01]) == owed_78
	fb.run(mut c, 2, .running, [])
	c.remote_dropped()
	assert !c.server.pending()
	assert c.server.routines[2].req.op == .stop
	assert passes(mut c, mut &now, mut t, 3).frames.len == 0
	// the session is the other transport's, the answer the bus's
	assert remote(mut c, [u8(0x10), 0x03])[0] == 0x50
	c.remote_sent()
	tsend(mut t, [u8(0x31), 0x01, 0x02, 0x01, 0x05])
	assert passes(mut c, mut &now, mut t, 3).answers == [owed_78]
	fb.run(mut c, 0, .running, [])
	c.remote_dropped()
	assert c.server.session == uds.session_default
	assert passes(mut c, mut &now, mut t, 3).answers == [[u8(0x7F), 0x31, 0x22]]
	assert c.server.routines[0].req.op == .stop
}

// A transport that never takes the owed answer: the FB is still told to stop at the timeout, and
// the server serves again P2*server_max later.
fn test_the_timeout_holds_whatever_the_transport_does() {
	mut c := rconn()
	mut t := rtester()
	mut fb := FbSim{}
	mut now := r_t0
	c.housekeep(now)
	assert remote(mut c, [u8(0x31), 0x01, 0x02, 0x03, 0x01]) == owed_78
	c.remote_sent()
	fb.run(mut c, 2, .running, [])
	now += uds.pending_repeat_us
	passes(mut c, mut &now, mut t, 1)
	assert push(mut c) == owed_78
	c.pushed(true) // and never acknowledged
	for now < r_t0 + 10_000_000 + 2000 {
		passes(mut c, mut &now, mut t, 1)
	}
	assert c.server.routines[2].req.op == .stop, 'the FB is told at the timeout'
	assert c.server.pending()
	tsend(mut t, [u8(0x3E), 0x00])
	assert passes(mut c, mut &now, mut t, 3).answers.len == 0, 'dropped while the 0x22 is owed'
	for now < r_t0 + 10_000_000 + uds.p2_star_server_us + 2000 {
		passes(mut c, mut &now, mut t, 1)
	}
	assert !c.server.pending()
	tsend(mut t, [u8(0x3E), 0x00])
	assert passes(mut c, mut &now, mut t, 3).answers == [[u8(0x7E), 0x00]]
}

// @verifies REQ-DIAG-084
// A tester that acknowledged the request's own 0x78 and then vanished without closing: a later
// push is never acknowledged, the routine times out and its 0x22 cannot be pushed; once the server
// gives that answer up the push is no longer waited for — S3 runs again and the next answer owed
// over DoIP is pushed.
fn test_an_answer_given_up_forgets_its_unacknowledged_push() {
	mut c := rconn()
	mut t := rtester()
	mut fb := FbSim{}
	mut now := r_t0
	c.housekeep(now)
	assert remote(mut c, [u8(0x10), 0x03])[0] == 0x50
	c.remote_sent()
	assert remote(mut c, [u8(0x31), 0x01, 0x02, 0x03, 0x01]) == owed_78
	c.remote_sent()
	fb.run(mut c, 2, .running, [])
	now += uds.pending_repeat_us
	passes(mut c, mut &now, mut t, 1)
	assert push(mut c) == owed_78
	c.pushed(true) // and never acknowledged
	for now < r_t0 + 10_000_000 + uds.p2_star_server_us + 2000 {
		passes(mut c, mut &now, mut t, 1)
	}
	assert !c.server.pending(), 'the 0x22 given up'
	assert c.server.session == uds.session_extended
	passes(mut c, mut &now, mut t, 2100)
	assert c.server.session == uds.session_default, 'S3 held by a push of an answer given up'
	// the next answer owed over DoIP
	fb.run(mut c, 2, .stopped, []) // the stop the timeout asked
	assert remote(mut c, [u8(0x31), 0x01, 0x02, 0x03, 0x01]) == owed_78
	c.remote_sent()
	fb.run(mut c, 2, .done, [u8(1), 2])
	assert push(mut c) == [u8(0x71), 0x01, 0x02, 0x03, 0x02, 1, 2], 'a push of an answer given up blocks the next'
}
