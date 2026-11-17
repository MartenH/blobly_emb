module uds

// @verifies REQ-DIAG-100 REQ-DIAG-101 REQ-DIAG-102 REQ-DIAG-103 REQ-DIAG-105 REQ-DIAG-106 REQ-DIAG-107 REQ-DIAG-004
// (0x2F InputOutputControlByIdentifier: served per control with its gate, the NRC order, the four
//  parameters and the 0x6F record, the value published and its range, control returned on a
//  session entry, S3, a reset and a relock, the application's refusal seam, functional requests
//  ignored.)
// Its own helpers: V compiles each _test.v of a module as its own program.

fn io_call(mut s Server, req []u8) []u8 {
	mut resp := [256]u8{}
	n := s.handle(&req[0], req.len, &resp[0])
	mut out := []u8{}
	for i in 0 .. n {
		out << resp[i]
	}
	return out
}

fn io_seed(_ voidptr, out &u8, n int) bool {
	for i in 0 .. n {
		unsafe {
			out[i] = u8(0x30 + i)
		}
	}
	return true
}

// a started server with four controls:
//   [0] 0x0200 u32, [0, 250], default 7, every parameter, extended|safety, no level
//   [1] 0x0201 u32, [0, 250], default 0, every parameter, extended, level 1
//   [2] 0x0202 i16, [-100, 100], default 0, every parameter, extended, no level
//   [3] 0x0203 bool, [0, 1], default 0, short-term adjustment only, extended, no level
fn io_server() Server {
	mut s := Server{}
	s.init(256)
	s.security = SecurityOps{
		seed:   io_seed
		key_ok: reference_key_ok
	}
	s.security_levels = 0x03
	s.ios[0] = IoControl{
		did:      0x0200
		width:    4
		lo:       0
		hi:       250
		dflt:     7
		params:   0x0F
		sessions: in_extended | in_safety
	}
	s.ios[1] = IoControl{
		did:      0x0201
		width:    4
		lo:       0
		hi:       250
		params:   0x0F
		sessions: in_extended
		security: 1
	}
	s.ios[2] = IoControl{
		did:      0x0202
		width:    2
		signed:   true
		lo:       -100
		hi:       100
		params:   0x0F
		sessions: in_extended
	}
	s.ios[3] = IoControl{
		did:      0x0203
		width:    1
		lo:       0
		hi:       1
		params:   0x09
		sessions: in_extended
	}
	s.nio = 4
	return s
}

fn io_extended(mut s Server) {
	assert io_call(mut s, [u8(0x10), 0x03])[0] == 0x50
}

// unlock `level` with the reference key (seed XOR 0xFF)
fn io_unlock(mut s Server, level u8) {
	seed := io_call(mut s, [u8(0x27), 2 * level - 1])[2..]
	mut key := [u8(0x27), 2 * level]
	for b in seed {
		key << b ^ 0xFF
	}
	assert io_call(mut s, key) == [u8(0x67), 2 * level]
}

fn io_set(mut s Server, did u16, v u32) []u8 {
	return io_call(mut s, [u8(0x2F), u8(did >> 8), u8(did), 0x03, u8(v >> 24), u8(v >> 16), u8(v >> 8),
		u8(v)])
}

fn test_a_server_with_no_control_does_not_serve_the_service() {
	mut s := Server{}
	s.init(256)
	assert !s.service_supported(0x2F)
	assert io_call(mut s, [u8(0x10), 0x03])[0] == 0x50
	assert io_call(mut s, [u8(0x2F), 0x02, 0x00, 0x00]) == [u8(0x7F), 0x2F, 0x11]
	mut c := io_server()
	assert c.service_supported(0x2F)
	io_extended(mut c)
	assert io_call(mut c, [u8(0x2F), 0x02, 0x00, 0x00])[0] == 0x6F
}

// REQ-DIAG-100: not served in the default session (the service's own default sessions), a table
// leaving it out answers 0x11, a row's level answers 0x33 while locked
fn test_the_service_row_comes_first() {
	mut s := io_server()
	assert io_call(mut s, [u8(0x2F), 0x02, 0x00, 0x00]) == [u8(0x7F), 0x2F, 0x7F]
	mut t := io_server()
	t.services[0] = Service{
		sid: 0x10
	}
	t.services[1] = Service{
		sid: 0x27
	}
	t.nservices = 2
	io_extended(mut t)
	assert io_call(mut t, [u8(0x2F), 0x02, 0x00, 0x00]) == [u8(0x7F), 0x2F, 0x11]
	t.services[2] = Service{
		sid:      0x2F
		security: 2
	}
	t.nservices = 3
	assert io_call(mut t, [u8(0x2F), 0x02, 0x00, 0x00]) == [u8(0x7F), 0x2F, 0x33]
	io_unlock(mut t, 2)
	assert io_call(mut t, [u8(0x2F), 0x02, 0x00, 0x00])[0] == 0x6F
}

// REQ-DIAG-101: each check in its place, and a request failing two answers the earlier one
fn test_the_negative_response_order() {
	mut s := io_server()
	// a table opening 0x2F in safety too, so the control's own sessions are what refuses there
	for i, r in [Service{
		sid: 0x10
	}, Service{
		sid: 0x27
	}, Service{
		sid:      0x2F
		sessions: in_extended | in_safety
	}] {
		s.services[i] = r
	}
	s.nservices = 3
	io_extended(mut s)
	// shorter than four bytes, even naming an unknown DID
	assert io_call(mut s, [u8(0x2F), 0x02, 0x00]) == [u8(0x7F), 0x2F, 0x13]
	assert io_call(mut s, [u8(0x2F), 0xAB]) == [u8(0x7F), 0x2F, 0x13]
	// an unknown DID, whatever its parameter or length
	assert io_call(mut s, [u8(0x2F), 0x01, 0x00, 0x03]) == [u8(0x7F), 0x2F, 0x31]
	assert io_call(mut s, [u8(0x2F), 0x01, 0x00, 0x09, 0x00]) == [u8(0x7F), 0x2F, 0x31]
	// outside the control's sessions: [1] is extended only
	assert io_call(mut s, [u8(0x10), 0x04])[0] == 0x50
	assert io_call(mut s, [u8(0x2F), 0x02, 0x01, 0x09]) == [u8(0x7F), 0x2F, 0x31]
	assert io_call(mut s, [u8(0x2F), 0x02, 0x00, 0x00])[0] == 0x6F // [0] is served in safety
	io_extended(mut s)
	// the level, before the length and the parameter
	assert io_call(mut s, [u8(0x2F), 0x02, 0x01, 0x00]) == [u8(0x7F), 0x2F, 0x33]
	assert io_call(mut s, [u8(0x2F), 0x02, 0x01, 0x09, 0x00]) == [u8(0x7F), 0x2F, 0x33]
	// the total length, before the parameter (ISO 14229-1's order): no controlEnableMask, a state
	// of exactly the width — for a parameter the control does not serve as for one it does
	assert io_call(mut s, [u8(0x2F), 0x02, 0x00, 0x00, 0xFF]) == [u8(0x7F), 0x2F, 0x13]
	assert io_call(mut s, [u8(0x2F), 0x02, 0x00, 0x01, 0xFF]) == [u8(0x7F), 0x2F, 0x13]
	assert io_call(mut s, [u8(0x2F), 0x02, 0x00, 0x03, 0x00, 0x00, 0x00]) == [u8(0x7F), 0x2F, 0x13]
	assert io_call(mut s, [u8(0x2F), 0x02, 0x00, 0x03, 0x00, 0x00, 0x00, 0x05, 0xFF]) == [u8(0x7F), 0x2F, 0x13]
	assert io_call(mut s, [u8(0x2F), 0x02, 0x03, 0x02, 0x00]) == [u8(0x7F), 0x2F, 0x13] // [3] serves 03 only
	assert io_call(mut s, [u8(0x2F), 0x02, 0x03, 0x01, 0x00, 0x00]) == [u8(0x7F), 0x2F, 0x13]
	// then a parameter above 03 (no length of its own: any length), or one the control does not serve
	assert io_call(mut s, [u8(0x2F), 0x02, 0x00, 0x04]) == [u8(0x7F), 0x2F, 0x31]
	assert io_call(mut s, [u8(0x2F), 0x02, 0x00, 0x04, 0x00, 0x00]) == [u8(0x7F), 0x2F, 0x31]
	assert io_call(mut s, [u8(0x2F), 0x02, 0x03, 0x01]) == [u8(0x7F), 0x2F, 0x31]
	assert io_call(mut s, [u8(0x2F), 0x02, 0x03, 0x02]) == [u8(0x7F), 0x2F, 0x31]
	// out of range, before the application's conditions
	s.io_ok = fn (did u16, param u8) bool {
		return false
	}
	assert io_set(mut s, 0x0200, 251) == [u8(0x7F), 0x2F, 0x31]
	assert io_set(mut s, 0x0200, 200) == [u8(0x7F), 0x2F, 0x22]
	held, _ := s.io_held(0)
	assert !held, 'a refused control took effect'
}

// a buffer too small for the answer: 0x14, nothing changed
fn test_an_answer_that_does_not_fit_changes_nothing() {
	mut s := io_server()
	s.resp_cap = min_resp_cap
	io_extended(mut s)
	assert io_set(mut s, 0x0200, 200) == [u8(0x7F), 0x2F, 0x14]
	held, _ := s.io_held(0)
	assert !held
	assert io_call(mut s, [u8(0x2F), 0x02, 0x03, 0x03, 0x01]) == [u8(0x6F), 0x02, 0x03, 0x03, 0x01] // one byte fits
}

// REQ-DIAG-102: shortTermAdjustment publishes the state, answered with the value from then on
fn test_short_term_adjustment() {
	mut s := io_server()
	io_extended(mut s)
	assert io_set(mut s, 0x0200, 200) == [u8(0x6F), 0x02, 0x00, 0x03, 0x00, 0x00, 0x00, 0xC8]
	held, v := s.io_held(0)
	assert held && v == 200
	assert s.io_published(0) == 200
	// the range's ends are values
	assert io_set(mut s, 0x0200, 0)[0] == 0x6F
	assert io_set(mut s, 0x0200, 250)[0] == 0x6F
	// a signed value: two's complement at its width, held to its range
	assert io_call(mut s, [u8(0x2F), 0x02, 0x02, 0x03, 0xFF, 0xFB]) == [u8(0x6F), 0x02, 0x02, 0x03, 0xFF, 0xFB]
	h2, v2 := s.io_held(2)
	assert h2 && v2 == -5
	assert io_call(mut s, [u8(0x2F), 0x02, 0x02, 0x03, 0x00, 0x65]) == [u8(0x7F), 0x2F, 0x31] // 101
	assert io_call(mut s, [u8(0x2F), 0x02, 0x02, 0x03, 0xFF, 0x9B]) == [u8(0x7F), 0x2F, 0x31] // -101
	assert io_call(mut s, [u8(0x2F), 0x02, 0x02, 0x03, 0xFF, 0x9C])[0] == 0x6F // -100
	// a bool: 0 or 1
	assert io_call(mut s, [u8(0x2F), 0x02, 0x03, 0x03, 0x01]) == [u8(0x6F), 0x02, 0x03, 0x03, 0x01]
	assert io_call(mut s, [u8(0x2F), 0x02, 0x03, 0x03, 0x02]) == [u8(0x7F), 0x2F, 0x31]
}

// REQ-DIAG-102: freezeCurrentState holds what is published at that moment
fn test_freeze_holds_the_value_published_now() {
	mut s := io_server()
	io_extended(mut s)
	// nothing published yet: the default, which the frame carries
	assert io_call(mut s, [u8(0x2F), 0x02, 0x00, 0x02]) == [u8(0x6F), 0x02, 0x00, 0x02, 0x00, 0x00, 0x00, 0x07]
	// the function block's noted value
	s.io_note(0, 120, true)
	assert io_call(mut s, [u8(0x2F), 0x02, 0x00, 0x00])[7] == 120 // returned: the FB's value again
	assert io_call(mut s, [u8(0x2F), 0x02, 0x00, 0x02])[7] == 120
	s.io_note(0, 90, true)
	assert s.io_published(0) == 120, 'a frozen value followed the function block'
	// an FB value past the range is frozen at what the encoder sends, the range's end
	io_call(mut s, [u8(0x2F), 0x02, 0x00, 0x00])
	s.io_note(0, 999, true)
	assert io_call(mut s, [u8(0x2F), 0x02, 0x00, 0x02])[7] == 250
	// a value already under control stays
	io_set(mut s, 0x0200, 200)
	s.io_note(0, 10, true)
	assert io_call(mut s, [u8(0x2F), 0x02, 0x00, 0x02])[7] == 200
	_, v := s.io_held(0)
	assert v == 200
}

// REQ-DIAG-102, REQ-DIAG-103: what is published is one rule — the FB's value held to the range as
// the encoder saturates it — and the DID read, the 00 answer and the freeze all give it
fn test_the_value_published_is_held_to_the_range() {
	mut s := io_server()
	io_extended(mut s)
	s.io_note(0, 300, true) // past hi: the frame carries 250
	assert s.io_published(0) == 250
	assert io_call(mut s, [u8(0x2F), 0x02, 0x00, 0x00])[7] == 250
	assert io_call(mut s, [u8(0x2F), 0x02, 0x00, 0x02])[7] == 250
	io_call(mut s, [u8(0x2F), 0x02, 0x00, 0x00])
	s.io_note(2, -500, true) // below lo
	assert s.io_published(2) == -100
	s.io_note(2, 33, true)
	assert s.io_published(2) == 33
}

// REQ-DIAG-102: resetToDefault publishes the default; returnControlToECU the FB's value, or the
// default before its first publish; 00 changes nothing when nothing is held
fn test_reset_to_default_and_return_control() {
	mut s := io_server()
	io_extended(mut s)
	assert io_call(mut s, [u8(0x2F), 0x02, 0x00, 0x00]) == [u8(0x6F), 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x07]
	h0, _ := s.io_held(0)
	assert !h0
	s.io_note(0, 100, true)
	assert io_call(mut s, [u8(0x2F), 0x02, 0x00, 0x01])[7] == 7
	held, v := s.io_held(0)
	assert held && v == 7
	assert io_call(mut s, [u8(0x2F), 0x02, 0x00, 0x00]) == [u8(0x6F), 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 100]
	h1, _ := s.io_held(0)
	assert !h1
	assert s.io_published(0) == 100
	// returnControlToECU is never refused by the application
	s.io_ok = fn (did u16, param u8) bool {
		return false
	}
	s.ios[0].held = io_short_term_adjustment
	s.ios[0].value = 42
	assert io_call(mut s, [u8(0x2F), 0x02, 0x00, 0x00])[0] == 0x6F
	h2, _ := s.io_held(0)
	assert !h2
}

// REQ-DIAG-106: the seam is asked with the DID and the parameter, and only for 01..03
fn test_the_application_seam_sees_the_did_and_the_parameter() {
	mut s := io_server()
	io_extended(mut s)
	s.io_ok = fn (did u16, param u8) bool {
		return !(did == 0x0200 && param == io_freeze_current_state)
	}
	assert io_call(mut s, [u8(0x2F), 0x02, 0x00, 0x02]) == [u8(0x7F), 0x2F, 0x22]
	assert io_call(mut s, [u8(0x2F), 0x02, 0x00, 0x01])[0] == 0x6F
	assert io_call(mut s, [u8(0x2F), 0x02, 0x02, 0x02])[0] == 0x6F
	// nil accepts
	s.io_ok = unsafe { nil }
	assert io_call(mut s, [u8(0x2F), 0x02, 0x00, 0x02])[0] == 0x6F
}

// REQ-DIAG-103: whatever is asked, a value under control lies inside [lo, hi]
fn test_a_value_under_control_is_always_in_range() {
	mut s := io_server()
	io_extended(mut s)
	mut x := u32(12345)
	for _ in 0 .. 2000 {
		x = x * 1103515245 + 12345
		fb := i64(x % 600) - 200
		s.io_note(0, fb, x & 0x100 != 0)
		sel := (x >> 12) % 4
		if sel == 3 {
			io_set(mut s, 0x0200, (x >> 16) % 400)
		} else {
			io_call(mut s, [u8(0x2F), 0x02, 0x00, u8(sel)])
		}
		held, v := s.io_held(0)
		if held {
			assert v >= 0 && v <= 250, 'value ${v} under control is out of range'
			assert s.io_published(0) == v
		}
	}
}

// REQ-DIAG-105: a return to default returns every control, by request or by S3
fn test_control_returns_on_the_default_session() {
	mut s := io_server()
	s.tick(1000)
	io_extended(mut s)
	io_set(mut s, 0x0200, 200)
	assert io_call(mut s, [u8(0x10), 0x01])[0] == 0x50
	h, _ := s.io_held(0)
	assert !h
	io_extended(mut s)
	io_set(mut s, 0x0200, 200)
	s.tick(1000 + default_s3_us + 2)
	assert s.session == session_default
	h2, _ := s.io_held(0)
	assert !h2, 'S3 left the control in force'
}

// REQ-DIAG-105: another session entry relocks — a gated control is returned, an ungated one kept
// where the new session is one of its own
fn test_a_session_entry_returns_what_it_relocks_or_leaves() {
	mut s := io_server()
	io_extended(mut s)
	io_unlock(mut s, 1)
	io_set(mut s, 0x0200, 200)
	io_set(mut s, 0x0201, 100)
	io_call(mut s, [u8(0x2F), 0x02, 0x02, 0x03, 0x00, 0x05])
	io_extended(mut s) // re-entry
	h0, _ := s.io_held(0)
	h1, _ := s.io_held(1)
	h2, _ := s.io_held(2)
	assert h0 && !h1 && h2
	// safety: [0] is served there, [2] is not
	assert io_call(mut s, [u8(0x10), 0x04])[0] == 0x50
	k0, _ := s.io_held(0)
	k2, _ := s.io_held(2)
	assert k0 && !k2
}

// REQ-DIAG-105: an ECU reset (the host's reset_state) returns every control
fn test_a_reset_returns_every_control() {
	mut s := io_server()
	io_extended(mut s)
	io_set(mut s, 0x0200, 200)
	s.reset_state()
	h, _ := s.io_held(0)
	assert !h
	assert s.io_published(0) == 7
}

// REQ-DIAG-105: unlocking another level relocks the one a control needed; a wrong key, or the
// same level again, does not; relocked returns a level's controls, 0 nothing
fn test_a_relock_returns_the_controls_it_gated() {
	mut s := io_server()
	io_extended(mut s)
	io_unlock(mut s, 1)
	io_set(mut s, 0x0201, 100)
	io_set(mut s, 0x0200, 50)
	// a wrong key at level 2 changes nothing
	seed := io_call(mut s, [u8(0x27), 0x03])[2..]
	assert io_call(mut s, [u8(0x27), 0x04, seed[0], seed[1], seed[2], seed[3]]) == [u8(0x7F), 0x27, 0x35]
	h, _ := s.io_held(1)
	assert h
	// the same level again: kept (its seed is all zeros, nothing relocked)
	assert io_call(mut s, [u8(0x27), 0x01]) == [u8(0x67), 0x01, 0, 0, 0, 0]
	h1, _ := s.io_held(1)
	assert h1
	// level 2 unlocked: level 1 is relocked, its control returned, the ungated one kept
	io_unlock(mut s, 2)
	g1, _ := s.io_held(1)
	g0, _ := s.io_held(0)
	assert !g1 && g0
	// relock: the unlock cleared where it is that level, its controls returned
	io_unlock(mut s, 1)
	io_set(mut s, 0x0201, 100)
	s.relock(0)
	r1, _ := s.io_held(1)
	assert r1 && s.unlocked == 1
	s.relock(2)
	r2, _ := s.io_held(1)
	assert r2 && s.unlocked == 1, 'another level\'s relock dropped the unlock'
	s.relock(1)
	r3, _ := s.io_held(1)
	r4, _ := s.io_held(0)
	assert !r3 && r4
	assert s.unlocked == 0, 'the relock left the level unlocked'
	assert io_set(mut s, 0x0201, 100) == [u8(0x7F), 0x2F, 0x33]
}

// the one rule a relock and a session entry return controls by (io_ends, relock_ends): a level, every
// other level, a session entry relocking security, a return to default
fn test_which_controls_a_gate_change_returns() {
	gated := IoControl{
		sessions: in_extended | in_safety
		security: 1
	}
	open := IoControl{
		sessions: in_extended
	}
	// a relock of level 1, of 0 (nothing), of 2
	assert io_ends(&gated, 1, false, 0) && !io_ends(&open, 1, false, 0)
	assert !io_ends(&gated, 0, false, 0) && !io_ends(&gated, 2, false, 0)
	// every level but 2 (a key unlocked 2), every level but 1
	assert io_ends(&gated, 2, true, 0) && !io_ends(&open, 2, true, 0)
	assert !io_ends(&gated, 1, true, 0)
	// a session entry: a gated control always, an open one where the session leaves it out
	assert io_ends(&gated, 0, false, session_extended)
	assert !io_ends(&open, 0, false, session_extended) && io_ends(&open, 0, false, session_safety)
	// a return to default returns even a control its sessions would keep
	assert io_ends(&IoControl{ sessions: in_default | in_extended }, 0, false, session_default)
	// the unlock and the routines read the same rule
	assert relock_ends(1, 1, false) && !relock_ends(0, 0, false) && !relock_ends(2, 1, false)
	assert relock_ends(2, 1, true) && !relock_ends(1, 1, true) && !relock_ends(0, 1, true)
}

// REQ-DIAG-107: a functional 0x2F is neither answered nor acted on, and keeps the session alive
fn test_a_functional_request_is_ignored() {
	mut s := io_server()
	s.tick(1000)
	io_extended(mut s)
	s.tick(1000 + default_s3_us - 10)
	req := [u8(0x2F), 0x02, 0x00, 0x03, 0x00, 0x00, 0x00, 0x05]
	mut resp := [64]u8{}
	assert s.handle_functional(&req[0], req.len, &resp[0]) == 0
	h, _ := s.io_held(0)
	assert !h
	s.tick(1000 + default_s3_us + 100)
	assert s.session == session_extended, 'a functional 0x2F did not keep the session alive'
}

// io_held / io_published / io_note ignore an index outside the table
fn test_out_of_table_indices_are_inert() {
	mut s := io_server()
	h, v := s.io_held(7)
	assert !h && v == 0
	assert s.io_published(-1) == 0
	s.io_note(9, 5, true)
	s.nio = 1
	h2, _ := s.io_held(2)
	assert !h2
}
