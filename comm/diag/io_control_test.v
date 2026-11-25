module diag

// @verifies REQ-DIAG-105
// 0x2F on a connection (docs/diagnostics.md §3.1 "Input/output control"): a control lasts while its
// gate would still grant it — the network tester's unlock ends with its connection, a reset the host
// owner applies returns every control — and the refresh before a dispatch is what 02 freezes.
// Its own helpers: V compiles each _test.v of a module as its own program.
import comm.isotp
import comm.uds
import driver.can

const io_rx = u32(0x7b0)
const io_tx = u32(0x7b8)

// a connection whose server serves 0x27 level 1 and holds two controls: [0] 0x0200 (u32, [0, 250],
// every parameter, extended, no level) and [1] 0x0201 (the same behind level 1)
fn io_conn() Connection {
	mut c := Connection{}
	req := []u8{len: isotp.default_message}
	resp := []u8{len: isotp.default_message}
	c.init(io_rx, io_tx, 0, 0, 0, &req[0], &resp[0], isotp.default_message)
	c.server.security = uds.SecurityOps{
		seed:   io_seed_fixed
		key_ok: uds.reference_key_ok
	}
	c.server.security_levels = 0x01
	c.server.ios[0] = uds.IoControl{
		did:      0x0200
		width:    4
		hi:       250
		params:   0x0F
		sessions: uds.in_extended
	}
	c.server.ios[1] = uds.IoControl{
		did:      0x0201
		width:    4
		hi:       250
		params:   0x0F
		sessions: uds.in_extended
		security: 1
	}
	c.server.nio = 2
	return c
}

fn io_seed_fixed(_ voidptr, out &u8, n int) bool {
	for i in 0 .. n {
		unsafe {
			out[i] = u8(0x10 + i)
		}
	}
	return true
}

fn io_tester() isotp.Link {
	mut t := isotp.Link{}
	t.init_defaults()
	rxb := []u8{len: isotp.message_limit}
	txb := []u8{len: isotp.message_limit}
	t.bind_rx(&rxb[0], isotp.message_limit)
	t.bind_tx(&txb[0], isotp.message_limit)
	return t
}

fn io_frame(id u32, p isotp.Pdu) &can.Frame {
	mut f := &can.Frame{
		id:  id
		len: 8
	}
	for i in 0 .. 8 {
		f.data[i] = p.data[i]
	}
	return f
}

fn io_sf(id u32, req []u8) &can.Frame {
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

// one owner pass, as diag_test.v's
fn io_pass(mut c Connection, now u64, mut t isotp.Link) {
	c.housekeep(now)
	mut p := isotp.Pdu{}
	for t.poll(now, mut p) {
		if c.on_frame(now, io_frame(io_rx, p)) == .request {
			break
		}
	}
	c.serve()
	mut f := can.Frame{}
	for c.produce(now, mut f) {
		mut q := isotp.Pdu{}
		for i in 0 .. 8 {
			q.data[i] = f.data[i]
		}
		t.on_frame(now, q)
	}
}

// a request over the bus, answered
fn io_bus(mut c Connection, mut t isotp.Link, mut now &u64, req []u8) []u8 {
	assert t.send(&req[0], req.len)
	for _ in 0 .. 50 {
		unsafe {
			*now += 1000
		}
		io_pass(mut c, *now, mut t)
		if t.has_request() {
			mut buf := []u8{len: isotp.message_limit}
			n := t.take(unsafe { &buf[0] })
			return buf[..n]
		}
	}
	assert false, 'no answer to ${req}'
	return []u8{}
}

// a request over the other transport (DoIP)
fn io_remote(mut c Connection, req []u8) []u8 {
	mut resp := [isotp.message_limit]u8{}
	n := c.serve_remote(&req[0], req.len, false, &resp[0])
	return resp[..n].clone()
}

fn io_key(seed []u8) []u8 {
	mut key := [u8(0x27), 0x02]
	for b in seed {
		key << b ^ 0xFF
	}
	return key
}

const io_set_1 = [u8(0x2F), 0x02, 0x01, 0x03, 0x00, 0x00, 0x00, 0x64] // 0x0201 = 100
const io_set_0 = [u8(0x2F), 0x02, 0x00, 0x03, 0x00, 0x00, 0x00, 0xC8] // 0x0200 = 200

fn io_held_at(c &Connection, i int) bool {
	held, _ := c.server.io_held(i)
	return held
}

// the network tester's unlock ends with its connection, and so does the control behind it — the
// bus owns the session, so no session entry returns it
fn test_a_network_testers_control_ends_with_its_connection() {
	mut c := io_conn()
	mut t := io_tester()
	mut now := u64(0)
	assert io_bus(mut c, mut t, mut &now, [u8(0x10), 0x03])[0] == 0x50
	seed := io_remote(mut c, [u8(0x27), 0x01])[2..]
	assert io_remote(mut c, io_key(seed)) == [u8(0x67), 0x02]
	assert io_remote(mut c, io_set_1)[0] == 0x6F
	assert io_remote(mut c, io_set_0)[0] == 0x6F
	assert io_held_at(c, 1) && io_held_at(c, 0)
	c.remote_dropped()
	assert c.server.session == uds.session_extended, 'the bus owns the session'
	assert !io_held_at(c, 1), 'the control outlived the unlock of the tester that disconnected'
	assert io_held_at(c, 0), 'an ungated control is the session\'s, not the tester\'s'
}

// a network tester that unlocked nothing takes nothing with it
fn test_a_bus_testers_control_survives_a_network_drop() {
	mut c := io_conn()
	mut t := io_tester()
	mut now := u64(0)
	assert io_bus(mut c, mut t, mut &now, [u8(0x10), 0x03])[0] == 0x50
	seed := io_bus(mut c, mut t, mut &now, [u8(0x27), 0x01])[2..]
	assert io_bus(mut c, mut t, mut &now, io_key(seed)) == [u8(0x67), 0x02]
	assert io_bus(mut c, mut t, mut &now, io_set_1)[0] == 0x6F
	assert io_bus(mut c, mut t, mut &now, io_set_0)[0] == 0x6F
	assert io_remote(mut c, [u8(0x22), 0xF1, 0x90]).len > 0 // a network request that changed nothing
	c.remote_dropped()
	assert io_held_at(c, 1) && io_held_at(c, 0)
}

// a reset the bus asked for hid the network tester's unlock; that tester drops: its control goes
// with it, and the bus answer then lost (the reset cancelled) brings back neither
fn test_a_held_back_unlock_takes_its_control_with_its_tester() {
	mut c := io_conn()
	c.server.serves_reset = true
	c.owner_resets = true
	mut t := io_tester()
	mut now := u64(0)
	assert io_bus(mut c, mut t, mut &now, [u8(0x10), 0x03])[0] == 0x50
	seed := io_remote(mut c, [u8(0x27), 0x01])[2..]
	assert io_remote(mut c, io_key(seed)) == [u8(0x67), 0x02]
	assert io_remote(mut c, io_set_1)[0] == 0x6F
	c.on_frame(now, io_sf(io_rx, [u8(0x11), 0x01]))
	c.serve() // the bus asks for a reset: the network's unlock held back
	assert c.server.unlocked == 0 && c.server.reset_req == 0x01
	assert io_held_at(c, 1), 'held back is not relocked'
	c.remote_dropped()
	assert !io_held_at(c, 1), 'the hidden unlock went, its control stayed'
	mut f := can.Frame{}
	assert c.produce(now, mut f)
	c.abort_tx() // the bus answer is lost: no reset
	assert c.server.reset_req == 0
	assert !io_held_at(c, 1) && c.server.unlocked == 0
}

// the host owner applies an answered ECUReset as the diagnostic state's power-on: every control back
fn test_an_answered_reset_returns_every_control_on_the_host() {
	mut c := io_conn()
	c.server.serves_reset = true
	mut t := io_tester()
	mut now := u64(0)
	assert io_bus(mut c, mut t, mut &now, [u8(0x10), 0x03])[0] == 0x50
	assert io_bus(mut c, mut t, mut &now, io_set_0)[0] == 0x6F
	assert io_bus(mut c, mut t, mut &now, [u8(0x11), 0x01]) == [u8(0x51), 0x01]
	c.housekeep(now + 1000)
	assert c.server.session == uds.session_default
	assert !io_held_at(c, 0), 'the reset left the control in force'
}

// the refresh runs before every dispatch, so 02 freezes the value the owner noted just then
fn test_freeze_takes_the_value_the_refresh_noted() {
	mut c := io_conn()
	mut t := io_tester()
	mut now := u64(0)
	c.refresh = fn (mut srv uds.Server) {
		srv.io_note(0, 77, true)
	}
	assert io_bus(mut c, mut t, mut &now, [u8(0x10), 0x03])[0] == 0x50
	assert io_bus(mut c, mut t, mut &now, [u8(0x2F), 0x02, 0x00, 0x02]) == [u8(0x6F), 0x02, 0x00, 0x02,
		0x00, 0x00, 0x00, 77]
	held, v := c.server.io_held(0)
	assert held && v == 77
}

// @verifies REQ-DIAG-085
// and so does the routine it started under that unlock: asked to stop when the tester drops, the
// bus's session standing
fn test_a_network_testers_routine_ends_with_its_unlock() {
	mut c := io_conn()
	c.server.routines[0] = uds.Routine{
		id:         0x0202
		sessions:   uds.in_extended
		security:   1
		async:      true
		stop:       true
		timeout_us: 10_000_000
	}
	c.server.nroutines = 1
	mut t := io_tester()
	mut now := u64(0)
	assert io_bus(mut c, mut t, mut &now, [u8(0x10), 0x03])[0] == 0x50
	seed := io_remote(mut c, [u8(0x27), 0x01])[2..]
	assert io_remote(mut c, io_key(seed)) == [u8(0x67), 0x02]
	assert io_remote(mut c, [u8(0x31), 0x01, 0x02, 0x02]) == [u8(0x7F), 0x31, 0x78]
	c.remote_sent()
	mut fb := uds.RoutineFb{}
	assert fb.take(&c.server.routines[0].req) == .start
	fb.report(.running, 0)
	c.server.routines[0].res = fb.res
	mut out := [16]u8{}
	assert c.push_step(&out[0], out.len) == 5 && out[0] == 0x71, 'the start answered running'
	c.pushed(true)
	c.push_sent()
	c.remote_dropped()
	assert c.server.session == uds.session_extended, 'the bus owns the session'
	assert fb.take(&c.server.routines[0].req) == .stop, 'the routine outlived the unlock it ran under'
}
