module diag

// @verifies REQ-DIAG-122 REQ-DIAG-123 REQ-DIAG-124 REQ-DIAG-125 REQ-DIAG-127 REQ-NET-012
// 0x29 Authentication on a connection, with the real keys (comm/udsauth) and the stepped verify:
// a 06 answered 0x78 and then its final answer on the bus (pump) and over the other transport
// (push_step), the unlock the OWING transport's — computed as that transport sees the server, the
// other's unlock hidden — a challenge asked over one transport not answerable over the other, a
// dropped connection voiding its challenge and counting the proof it was owed an answer for,
// deAuthenticate over the bus leaving the network's unlock, and 0x27 not served.
import bcrypto
import comm.isotp
import comm.uds
import comm.udsauth
import driver.can

const a_rx = u32(0x7b0)
const a_tx = u32(0x7b8)
const a_fid = u32(0x7df)

const dev_seed = [u8(0x20), 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x2b,
	0x2c, 0x2d, 0x2e, 0x2f, 0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x3b,
	0x3c, 0x3d, 0x3e, 0x3f]!

// AuthConn: a connection whose server unlocks level 1 by 0x29 with the reference key, its challenges
// from the reference generator — the keys and the generator beside it, since the ops point at them
struct AuthConn {
mut:
	keys udsauth.Keys
	gen  uds.ReferenceSecurity
	c    Connection
}

fn auth_conn() &AuthConn {
	mut a := &AuthConn{}
	req := []u8{len: 520}
	resp := []u8{len: 520}
	a.c.init(a_rx, a_tx, a_fid, 0, 0, &req[0], &resp[0], 520)
	a.c.server.dids[0] = uds.Did{
		id:             0x0102
		writable:       true
		len:            1
		write_sessions: uds.in_extended
		write_security: 1
	}
	a.c.server.ndid = 1
	a.keys.set(1, &udsauth.reference_key[0])
	a.c.server.security = a.gen.ops(0x1234_5678)
	a.c.server.auth = a.keys.ops()
	a.c.server.security_levels = 0x01
	return a
}

fn a_tester() isotp.Link {
	mut t := isotp.Link{}
	t.init_defaults()
	rxb := []u8{len: isotp.message_limit}
	txb := []u8{len: isotp.message_limit}
	t.bind_rx(&rxb[0], isotp.message_limit)
	t.bind_tx(&txb[0], isotp.message_limit)
	return t
}

// AWire records what a pump puts on the bus
struct AWire {
mut:
	tx []can.Frame
}

fn (mut w AWire) tx_ready() bool {
	return true
}

fn (mut w AWire) send(f can.Frame) bool {
	w.tx << f
	return true
}

// a_pass: one owner pass as the generated owners run it — housekeep, the drain, serve, pump (the
// owed answer's step first) — the frames handed to the tester; an answer it reassembled, if any
fn a_pass(mut c Connection, now u64, mut t isotp.Link) ?[]u8 {
	c.housekeep(now)
	mut p := isotp.Pdu{}
	for t.poll(now, mut p) {
		mut f := &can.Frame{
			id:  a_rx
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
	mut w := AWire{}
	c.pump(now, mut w)
	for f in w.tx {
		mut q := isotp.Pdu{}
		for i in 0 .. 8 {
			q.data[i] = f.data[i]
		}
		t.on_frame(now, q)
	}
	if t.has_request() {
		mut buf := []u8{len: isotp.message_limit}
		n := t.take(unsafe { &buf[0] })
		return buf[..n].clone()
	}
	return none
}

// bus: send `req` over CAN and run passes 1 ms apart until its final answer; every answer it got, in
// order (responsePendings first)
fn bus(mut c Connection, mut t isotp.Link, mut now &u64, req []u8) [][]u8 {
	assert t.send(&req[0], req.len)
	mut got := [][]u8{}
	for _ in 0 .. 500 {
		unsafe {
			*now += 1000
		}
		if a := a_pass(mut c, *now, mut t) {
			got << a
			if !(a.len == 3 && a[0] == 0x7F && a[2] == 0x78) {
				return got
			}
		}
	}
	assert false, 'no final answer to ${req}: ${got}'
	return got
}

// doip_push_max: driver/doipnet push_max, what a generated owner passes push_step over DoIP (the
// import would be a cycle: doipnet -> diagroute -> diag); driver/doipnet's test pins it equal
const doip_push_max = 24

// net: `req` over the other transport, then every pushed response, each acknowledged, until the
// final one — pushed at the DoIP push slot's size, as a generated owner pushes; every answer in order
fn net(mut c Connection, req []u8) [][]u8 {
	return net_cap(mut c, req, doip_push_max)
}

// net_cap: net, its responses pushed into `cap` bytes, a pass (housekeep) before each push
fn net_cap(mut c Connection, req []u8, cap int) [][]u8 {
	mut resp := []u8{len: 520}
	n := c.serve_remote(&req[0], req.len, false, unsafe { &resp[0] })
	mut got := [resp[..n].clone()]
	c.remote_sent()
	for _ in 0 .. 500 {
		if got.last().len == 3 && got.last()[0] == 0x7F && got.last()[2] == 0x78 {
			c.housekeep(c.server.now_us + 1000) // a pass: the verify advances in its tick
			m := c.push_step(unsafe { &resp[0] }, cap)
			if m > 0 {
				c.pushed(true)
				c.push_sent()
				got << resp[..m].clone()
			}
		} else {
			return got
		}
	}
	assert false, 'no final answer to ${req}: ${got}'
	return got
}

fn ch_req() []u8 {
	mut r := [u8(0x29), 0x05, 0x01]
	r << uds.ed25519_algorithm[..]
	return r
}

// proof_req: 0x29 06 signing the challenge in a 05 answer with the dev seed
fn proof_req(ans05 []u8) []u8 {
	assert ans05.len == uds.auth_challenge_answer_len && ans05[0] == 0x69, 'no challenge: ${ans05}'
	mut msg := uds.auth_context[..].clone() // the application message: the context, level 1, the challenge
	msg << u8(1)
	msg << ans05[uds.auth_answer_challenge_at..uds.auth_answer_challenge_at + uds.auth_challenge_len]
	sig := bcrypto.sign(dev_seed, msg)
	mut r := [u8(0x29), 0x06]
	r << uds.ed25519_algorithm[..]
	r << [u8(0x00), 0x40]
	r << sig[..]
	r << [u8(0), 0, 0, 0]
	return r
}

fn verified() []u8 {
	mut a := [u8(0x69), 0x06, 0x12]
	a << uds.ed25519_algorithm[..]
	a << [u8(0), 0]
	return a
}

const pending = [u8(0x7F), 0x29, 0x78]

fn test_a_proof_is_answered_pending_then_verified_on_either_transport() {
	mut a := auth_conn()
	mut t := a_tester()
	mut now := u64(0)
	assert bus(mut a.c, mut t, mut &now, [u8(0x10), 0x03])[0][0] == 0x50
	// over CAN: 0x78 as a single frame, then the answer once the verify (about 75 passes) is done
	ans := bus(mut a.c, mut t, mut &now, ch_req())
	got := bus(mut a.c, mut t, mut &now, proof_req(ans[0]))
	assert got == [pending, verified()]
	assert a.c.server.unlocked == 1 && a.c.remote_unlocked() == 0, "the bus's unlock is the bus's"
	// over DoIP: the 0x78 is the request's answer, the final one pushed once it was acknowledged
	ip := net(mut a.c, ch_req())
	assert net(mut a.c, proof_req(ip[0])) == [pending, verified()]
	assert a.c.remote_unlocked() == 1, "the network's unlock went to the bus"
	assert net(mut a.c, [u8(0x2E), 0x01, 0x02, 0x11])[0] == [u8(0x6E), 0x01, 0x02]
	assert bus(mut a.c, mut t, mut &now, [u8(0x2E), 0x01, 0x02, 0x11])[0] == [u8(0x7F), 0x2E, 0x33]
}

// @verifies REQ-DIAG-122 REQ-DIAG-124 REQ-NET-012 — a challenge asked over one transport is not
// answerable over the other (0x24), each transport's challenge is its own, a dropped network
// connection voids its challenge, and deAuthenticate over the bus leaves the network's unlock.
fn test_authentication_is_per_transport() {
	mut a := auth_conn()
	mut t := a_tester()
	mut now := u64(0)
	bus(mut a.c, mut t, mut &now, [u8(0x10), 0x03])
	// asked over CAN, answered over DoIP: refused
	can_ans := bus(mut a.c, mut t, mut &now, ch_req())[0]
	assert net(mut a.c, proof_req(can_ans)) == [[u8(0x7F), 0x29, 0x24]]
	// DoIP asks its own in between: the CAN challenge stands
	ip_ans := net(mut a.c, ch_req())[0]
	assert bus(mut a.c, mut t, mut &now, proof_req(can_ans)).last() == verified()
	assert net(mut a.c, proof_req(ip_ans)).last() == verified()
	assert a.c.remote_unlocked() == 1
	// deAuthenticate over CAN: the bus relocks, the network keeps its unlock
	assert bus(mut a.c, mut t, mut &now, [u8(0x29), 0x00]) == [[u8(0x69), 0x00, 0x10]]
	assert a.c.remote_unlocked() == 1, "the bus's deAuthenticate took the network's unlock"
	assert net(mut a.c, [u8(0x2E), 0x01, 0x02, 0x11])[0] == [u8(0x6E), 0x01, 0x02]
	assert bus(mut a.c, mut t, mut &now, [u8(0x2E), 0x01, 0x02, 0x11])[0] == [u8(0x7F), 0x2E, 0x33]
	// a dropped connection voids its challenge (and its unlock)
	ip2 := net(mut a.c, ch_req())[0]
	a.c.remote_dropped()
	assert net(mut a.c, proof_req(ip2)) == [[u8(0x7F), 0x29, 0x24]]
	assert a.c.remote_unlocked() == 0
	// a wrong proof over the bus counts like a wrong key
	bad := bus(mut a.c, mut t, mut &now, ch_req())[0]
	mut wrong := proof_req(bad)
	wrong[uds.auth_proof_at] ^= 1
	assert bus(mut a.c, mut t, mut &now, wrong) == [pending, [u8(0x7F), 0x29, 0x58]]
	assert a.c.server.sa_since[0] == 1
	// 0x27 is not served on such a node
	assert bus(mut a.c, mut t, mut &now, [u8(0x27), 0x01]) == [[u8(0x7F), 0x27, 0x11]]
}

// REQ-DIAG-123: a proof whose network connection drops while it is verified is counted — dropping
// the connection buys no attempt — and no answer is pushed for it
fn test_a_dropped_connection_counts_the_proof_it_was_verifying() {
	mut a := auth_conn()
	net(mut a.c, [u8(0x10), 0x03])
	ip := net(mut a.c, ch_req())[0]
	r := proof_req(ip)
	mut resp := []u8{len: 520}
	n := a.c.serve_remote(&r[0], r.len, false, unsafe { &resp[0] })
	assert resp[..n] == pending
	a.c.remote_sent()
	a.c.remote_dropped()
	assert a.c.server.sa_since[0] == 1, 'a dropped verify was not counted'
	assert !a.c.server.pending()
	assert a.c.push_step(unsafe { &resp[0] }, resp.len) == 0
	assert a.c.server.unlocked == 0
}

// REQ-DIAG-122 / REQ-NET-012: a proof owed over the BUS verified while the network holds an unlock —
// the verdict is computed as the bus sees the server (owed_step on the bus side too), so the unlock
// is the bus's and the network's is hidden, not handed the bus's level
fn test_a_bus_proof_verified_while_the_network_holds_an_unlock_is_the_buss() {
	mut a := auth_conn()
	mut t := a_tester()
	mut now := u64(0)
	net(mut a.c, [u8(0x10), 0x03])
	ip := net(mut a.c, ch_req())[0]
	assert net(mut a.c, proof_req(ip)).last() == verified()
	assert a.c.remote_unlocked() == 1
	can_ans := bus(mut a.c, mut t, mut &now, ch_req())[0]
	assert bus(mut a.c, mut t, mut &now, proof_req(can_ans)) == [pending, verified()]
	assert a.c.remote_unlocked() == 0, 'the bus proof left the unlock with the network'
	assert bus(mut a.c, mut t, mut &now, [u8(0x2E), 0x01, 0x02, 0x11])[0] == [u8(0x6E), 0x01, 0x02]
}

// REQ-DIAG-125 / 033: a challenge drawn over one transport before failed proofs over the other
// started the lockout buys no proof during it — 0x37, never verified or counted, the challenge void
fn test_a_challenge_drawn_before_a_lockout_buys_no_proof_during_it() {
	mut a := auth_conn()
	mut t := a_tester()
	mut now := u64(0)
	bus(mut a.c, mut t, mut &now, [u8(0x10), 0x03])
	ip := net(mut a.c, ch_req())[0]
	for want in [u8(0x58), 0x58, 0x36] {
		mut wrong := proof_req(bus(mut a.c, mut t, mut &now, ch_req())[0])
		wrong[uds.auth_proof_at] ^= 1
		assert bus(mut a.c, mut t, mut &now, wrong) == [pending, [u8(0x7F), 0x29, want]]
	}
	assert net(mut a.c, proof_req(ip)) == [[u8(0x7F), 0x29, 0x37]], 'a proof was verified during the lockout'
	assert a.c.server.unlocked == 0 && a.c.server.sa_since[0] == 3 && a.c.server.sa_failed[0] == 0
	assert net(mut a.c, proof_req(ip)) == [[u8(0x7F), 0x29, 0x24]], 'the challenge outlived its refusal'
}

// REQ-DIAG-127: a valid proof whose answer the owing transport cannot carry unlocks nothing and is
// not counted — 0x14, so no tester is told a proof failed that unlocked the ECU
fn test_a_proof_whose_answer_does_not_fit_unlocks_nothing() {
	mut a := auth_conn()
	net(mut a.c, [u8(0x10), 0x03])
	ip := net(mut a.c, ch_req())[0]
	got := net_cap(mut a.c, proof_req(ip), uds.auth_proof_answer_len - 1)
	assert got == [pending, [u8(0x7F), 0x29, 0x14]]
	assert a.c.server.unlocked == 0 && a.c.remote_unlocked() == 0 && a.c.server.sa_since[0] == 0
}

// REQ-DIAG-127: a bus proof whose session the network tester ends mid-verify (it owned the session
// and its connection dropped) is answered 0x22 and NOT counted — the other transport's doing, never
// judged — so three such valid proofs leave no count and no lockout
fn test_a_bus_proof_voided_by_the_other_transport_is_not_counted() {
	mut a := auth_conn()
	mut t := a_tester()
	mut now := u64(0)
	for _ in 0 .. 3 {
		bus(mut a.c, mut t, mut &now, [u8(0x10), 0x03])
		assert net(mut a.c, [u8(0x10), 0x03])[0][0] == 0x50 // the network tester owns the session
		r := proof_req(bus(mut a.c, mut t, mut &now, ch_req())[0])
		assert t.send(&r[0], r.len)
		mut got := [][]u8{}
		for i in 0 .. 500 {
			now += 1000
			if i == 5 {
				assert a.c.server.pending() && !a.c.server.auth_decided, 'the verify ended early'
				a.c.remote_dropped()
			}
			if ans := a_pass(mut a.c, now, mut t) {
				got << ans
				if ans != pending {
					break
				}
			}
		}
		assert got == [pending, [u8(0x7F), 0x29, 0x22]]
		assert a.c.server.sa_since[0] == 0 && a.c.server.unlocked == 0, 'a voided proof was counted'
	}
	bus(mut a.c, mut t, mut &now, [u8(0x10), 0x03])
	ans := bus(mut a.c, mut t, mut &now, ch_req())[0]
	assert ans[0] == 0x69, 'the voided proofs locked the level out: ${ans}'
	assert bus(mut a.c, mut t, mut &now, proof_req(ans)) == [pending, verified()]
}

// DStore is a RAM journal block (uds sa_store.v's seam)
struct DStore {
mut:
	cell [16]u8
	len  int
}

fn d_put(ctx voidptr, _ u16, data &u8, len u16) bool {
	mut f := unsafe { &DStore(ctx) }
	for i in 0 .. int(len) {
		f.cell[i] = unsafe { data[i] }
	}
	f.len = int(len)
	return true
}

fn d_get(ctx voidptr, _ u16, out &u8, cap u16) u16 {
	f := unsafe { &DStore(ctx) }
	n := if f.len < int(cap) { f.len } else { int(cap) }
	for i in 0 .. n {
		unsafe {
			out[i] = f.cell[i]
		}
	}
	return u16(n)
}

// JWire is a bus that notes, for each frame put on it, level 1's count the journal held then
struct JWire {
mut:
	st &DStore = unsafe { nil }
	tx []can.Frame
	at []u8
}

fn (mut w JWire) tx_ready() bool {
	return true
}

fn (mut w JWire) send(f can.Frame) bool {
	w.tx << f
	w.at << w.st.cell[2]
	return true
}

// @verifies REQ-DIAG-067 REQ-DIAG-123 — on a CAN link, whose owed answer leaves inside the pass's
// pump (after its persist step), a correct proof's cleared count is in the journal before the first
// frame of ownershipVerified is on the bus — the owner's pass as generated: housekeep, serve,
// persist_security, pump
fn test_a_correct_proofs_cleared_count_is_persisted_before_its_answer_on_can() {
	mut a := auth_conn()
	mut st := &DStore{}
	a.c.server.sa_store = uds.SecurityStore{
		ctx:      unsafe { voidptr(st) }
		put:      d_put
		get:      d_get
		id:       0x044E
		retry_us: 1_000_000
	}
	a.c.server.restore_persisted_security()
	mut t := a_tester()
	mut now := u64(0)
	bus(mut a.c, mut t, mut &now, [u8(0x10), 0x03])
	mut wrong := proof_req(bus(mut a.c, mut t, mut &now, ch_req())[0])
	wrong[uds.auth_proof_at] ^= 1
	assert bus(mut a.c, mut t, mut &now, wrong) == [pending, [u8(0x7F), 0x29, 0x58]]
	a.c.server.persist_security(false)
	assert st.cell[2] == 1
	r := proof_req(bus(mut a.c, mut t, mut &now, ch_req())[0])
	assert t.send(&r[0], r.len)
	mut answer_count := -1
	for _ in 0 .. 500 {
		now += 1000
		a.c.housekeep(now)
		mut p := isotp.Pdu{}
		for t.poll(now, mut p) {
			mut f := &can.Frame{
				id:  a_rx
				len: 8
			}
			for i in 0 .. 8 {
				f.data[i] = p.data[i]
			}
			if a.c.on_frame(now, f) == .request {
				break
			}
		}
		a.c.serve()
		a.c.server.persist_security(false)
		mut w := JWire{
			st: st
		}
		a.c.pump(now, mut w)
		for i, f in w.tx {
			// the first frame of ownershipVerified: a First Frame carrying 69 06 12
			if f.data[0] & 0xF0 == 0x10 && f.data[2] == 0x69 && f.data[3] == 0x06 {
				answer_count = w.at[i]
			}
			mut q := isotp.Pdu{}
			for k in 0 .. 8 {
				q.data[k] = f.data[k]
			}
			t.on_frame(now, q)
		}
		if answer_count >= 0 {
			break
		}
	}
	assert answer_count == 0, 'ownershipVerified went on the bus while the journal held the failed proof (${answer_count})'
	assert a.c.server.unlocked == 1
}
