module uds

// @verifies SYS-REQ-DIAG-001 REQ-DIAG-001 REQ-DIAG-003 REQ-DIAG-004 REQ-DIAG-005 REQ-DIAG-006 REQ-DIAG-007
// (service dispatch with positive/negative responses, unknown-service/DID NRCs, the
//  suppressPosRspMsgIndicationBit silence; sessions + S3 (003), NRC order + session/security
//  gating (004), multi-DID reads (005), functional-request silence (006), 0x11/0x28 (007).)

fn call(mut s Server, req []u8) []u8 {
	mut resp := [256]u8{}
	n := s.handle(&req[0], req.len, &resp[0])
	mut out := []u8{}
	for i in 0 .. n {
		out << resp[i]
	}
	return out
}

fn fixture() Server {
	mut s := Server{}
	s.dids[0] = Did{
		id:  0xF190
		len: 2
	}
	s.dids[0].data[0] = 0xAB
	s.dids[0].data[1] = 0xCD
	s.dids[1] = Did{
		id:       0xF1AA
		writable: true
	}
	s.ndid = 2
	return s
}

fn test_tester_present() {
	mut s := fixture()
	assert call(mut s, [u8(0x3E), 0x00]) == [u8(0x7E), 0x00]
	// suppressPosRsp bit -> no response
	assert call(mut s, [u8(0x3E), 0x80]).len == 0
}

fn test_session_control_suppressed() {
	mut s := Server{}
	mut resp := [64]u8{}
	// 10 83: extended session WITH suppressPosRsp — the session must change, the
	// positive response must not come (the suppress bit is not part of the session)
	req := [u8(0x10), 0x83]
	assert s.handle(&req[0], 2, &resp[0]) == 0
	assert s.session == 0x03
}

fn test_session_control_invalid_subfunction() {
	mut s := Server{}
	mut resp := [64]u8{}
	// 10 FF: suppress bit set, but session 0x7F is unsupported — suppression applies
	// only to a SUCCESSFUL positive response, so this must be a negative response and
	// must NOT mutate the session (codex #218)
	req := [u8(0x10), 0xFF]
	n := s.handle(&req[0], 2, &resp[0])
	assert n == 3
	assert resp[0] == 0x7F && resp[1] == 0x10 && resp[2] == 0x12 // subFunctionNotSupported
	assert s.session == 0x00 // unchanged from init
}

fn test_tester_present_invalid_subfunction() {
	mut s := Server{}
	mut resp := [64]u8{}
	// 3E 81: suppress bit set, but subfunction 0x01 is invalid for TesterPresent —
	// a negative response is required even with suppression (codex #218)
	req := [u8(0x3E), 0x81]
	assert s.handle(&req[0], 2, &resp[0]) == 3
	assert resp[0] == 0x7F && resp[1] == 0x3E && resp[2] == 0x12
}

fn test_session_control() {
	mut s := fixture()
	r := call(mut s, [u8(0x10), 0x03])
	assert r[0] == 0x50 && r[1] == 0x03
	assert r.len == 6
	assert s.session == 0x03
}

fn test_read_did_constant() {
	mut s := fixture()
	assert call(mut s, [u8(0x22), 0xF1, 0x90]) == [u8(0x62), 0xF1, 0x90, 0xAB, 0xCD]
}

fn test_read_did_unknown_is_out_of_range() {
	mut s := fixture()
	assert call(mut s, [u8(0x22), 0x00, 0x01]) == [u8(0x7F), 0x22, 0x31]
}

fn test_write_then_read_roundtrip() {
	mut s := fixture()
	assert call(mut s, [u8(0x2E), 0xF1, 0xAA, 0xCA, 0xFE]) == [u8(0x6E), 0xF1, 0xAA]
	assert call(mut s, [u8(0x22), 0xF1, 0xAA]) == [u8(0x62), 0xF1, 0xAA, 0xCA, 0xFE]
}

fn test_write_readonly_did_rejected() {
	mut s := fixture()
	// 0xF190 is not writable: ISO 14229-1 treats a DID that cannot be written as NOT SUPPORTED
	// for 0x2E -> requestOutOfRange (it was conditionsNotCorrect before the NRC order was fixed)
	assert call(mut s, [u8(0x2E), 0xF1, 0x90, 0x00]) == [u8(0x7F), 0x2E, 0x31]
}

fn test_unknown_service_rejected() {
	mut s := fixture()
	assert call(mut s, [u8(0x33), 0x00]) == [u8(0x7F), 0x33, 0x11]
}

fn started() Server {
	mut s := fixture()
	s.init(256)
	s.serves_reset = true
	s.serves_comm_control = true
	return s
}

// Every SID service_supported() admits must reach a handler: a SID listed there but missing
// from dispatch()'s match would answer serviceNotSupported with no compile error.
fn test_every_supported_service_dispatches() {
	mut s := started()
	call(mut s, [u8(0x10), 0x03])
	for sid in 0 .. 256 {
		if !s.service_supported(u8(sid)) {
			continue
		}
		r := call(mut s, [u8(sid), 0x00, 0x00, 0x00])
		assert !(r.len == 3 && r[0] == 0x7F && r[2] == 0x11), 'SID 0x${u8(sid).hex()} is supported but not dispatched'
	}
}

// An owner that does not act on 0x11 / 0x28 must not acknowledge them.
fn test_reset_and_comm_control_are_opt_in_per_owner() {
	mut s := fixture()
	s.init(256)
	assert call(mut s, [u8(0x11), 0x01]) == [u8(0x7F), 0x11, 0x11]
	s.session = session_extended
	assert call(mut s, [u8(0x28), 0x01, 0xF1]) == [u8(0x7F), 0x28, 0x11]
}

// REQ-DIAG-003: a server starts in the default session and S3 returns it there.
fn test_init_enters_default_and_s3_returns_to_it() {
	mut s := started()
	assert s.session == session_default
	s.tick(1_000_000)
	assert call(mut s, [u8(0x10), 0x03])[0] == 0x50
	s.tick(1_000_000 + default_s3_us) // exactly S3: still alive
	assert s.session == session_extended
	s.tick(1_000_000 + default_s3_us + 1)
	assert s.session == session_default, 'S3 did not return to default'
	// any request keeps it alive
	assert call(mut s, [u8(0x10), 0x03])[0] == 0x50
	s.tick(9_000_000)
	assert call(mut s, [u8(0x3E), 0x00]) == [u8(0x7E), 0x00]
	s.tick(9_000_000 + default_s3_us)
	assert s.session == session_extended
}

// REQ-DIAG-003: every session transition relocks security; returning to default re-enables
// communication.
fn test_session_transitions_relock_and_restore_communication() {
	mut s := started()
	call(mut s, [u8(0x10), 0x03])
	s.unlocked = 1
	assert call(mut s, [u8(0x28), 0x03, 0xF1]) == [u8(0x68), 0x03]
	assert !s.tx_enabled() && !s.rx_enabled()
	call(mut s, [u8(0x10), 0x03]) // same session: security survives
	assert s.unlocked == 1
	call(mut s, [u8(0x10), 0x01])
	assert s.unlocked == 0
	assert s.tx_enabled() && s.rx_enabled()
}

// REQ-DIAG-003: an application server refuses the programming session (no handoff yet).
fn test_application_server_refuses_programming() {
	mut s := started()
	s.no_programming = true
	assert call(mut s, [u8(0x10), 0x02]) == [u8(0x7F), 0x10, 0x12]
	assert s.session == session_default
	s.no_programming = false // the bootloader's server
	assert call(mut s, [u8(0x10), 0x02])[0] == 0x50
}

// REQ-DIAG-004: evaluation order — unsupported service beats everything, a service gated out
// of the session answers 0x7F before its length is looked at, length before range.
fn test_nrc_evaluation_order() {
	mut s := started()
	assert call(mut s, [u8(0x19)]) == [u8(0x7F), 0x19, 0x11]
	assert call(mut s, [u8(0x28)]) == [u8(0x7F), 0x28, 0x7F], '0x28 in default must be 0x7F, not 0x13'
	call(mut s, [u8(0x10), 0x03])
	assert call(mut s, [u8(0x28)]) == [u8(0x7F), 0x28, 0x13]
	assert call(mut s, [u8(0x28), 0x07, 0x01]) == [u8(0x7F), 0x28, 0x12]
	assert call(mut s, [u8(0x28), 0x00, 0x05]) == [u8(0x7F), 0x28, 0x31]
	assert call(mut s, [u8(0x22), 0xF1]) == [u8(0x7F), 0x22, 0x13]
	assert call(mut s, [u8(0x3E), 0x00, 0x00]) == [u8(0x7F), 0x3E, 0x13]
	// a never-initialised server is in no session: gated services are refused (fail-closed)
	mut raw := fixture()
	raw.serves_comm_control = true
	assert call(mut raw, [u8(0x28), 0x00, 0x01]) == [u8(0x7F), 0x28, 0x7F]
}

// REQ-DIAG-004: per-DID session and security gating.
fn test_did_session_and_security_gating() {
	mut s := started()
	s.dids[1].write_sessions = in_extended
	s.dids[0].read_sessions = in_extended
	// not readable in default: the only DID asked for is unanswered -> 0x31
	assert call(mut s, [u8(0x22), 0xF1, 0x90]) == [u8(0x7F), 0x22, 0x31]
	assert call(mut s, [u8(0x2E), 0xF1, 0xAA, 0x01]) == [u8(0x7F), 0x2E, 0x31]
	call(mut s, [u8(0x10), 0x03])
	assert call(mut s, [u8(0x22), 0xF1, 0x90]) == [u8(0x62), 0xF1, 0x90, 0xAB, 0xCD]
	s.dids[1].write_security = 1
	assert call(mut s, [u8(0x2E), 0xF1, 0xAA, 0x01]) == [u8(0x7F), 0x2E, 0x33]
	s.unlocked = 1
	assert call(mut s, [u8(0x2E), 0xF1, 0xAA, 0x01]) == [u8(0x6E), 0xF1, 0xAA]
	// too long a record is a LENGTH error, after security
	mut long := [u8(0x2E), 0xF1, 0xAA]
	for _ in 0 .. max_did_data + 1 {
		long << 0x55
	}
	assert call(mut s, long) == [u8(0x7F), 0x2E, 0x13]
}

// REQ-DIAG-005: several DIDs per 0x22, in request order; unsupported ones skipped; 0x31 only when
// none answer; 0x14 when the response would not fit the owner's buffer.
fn test_multi_did_read() {
	mut s := started()
	call(mut s, [u8(0x2E), 0xF1, 0xAA, 0x11, 0x22])
	assert call(mut s, [u8(0x22), 0xF1, 0xAA, 0xF1, 0x90]) == [u8(0x62), 0xF1, 0xAA, 0x11, 0x22,
		0xF1, 0x90, 0xAB, 0xCD]
	assert call(mut s, [u8(0x22), 0x00, 0x01, 0xF1, 0x90]) == [u8(0x62), 0xF1, 0x90, 0xAB, 0xCD]
	assert call(mut s, [u8(0x22), 0x00, 0x01, 0x00, 0x02]) == [u8(0x7F), 0x22, 0x31]
	assert call(mut s, [u8(0x22), 0xF1, 0x90, 0xF1]) == [u8(0x7F), 0x22, 0x13] // odd DID bytes
	s.init(6) // a 6-byte buffer: one 2-byte DID fits (5 B), two do not
	assert call(mut s, [u8(0x22), 0xF1, 0x90]).len == 5
	assert call(mut s, [u8(0x22), 0xF1, 0x90, 0xF1, 0xAA]) == [u8(0x7F), 0x22, 0x14]
}

// REQ-DIAG-005: a caller that never called init() keeps the legacy single-DID bound, so its
// buffer (sized for one DID) is never overrun by a multi-DID response.
fn test_uninitialised_caller_keeps_the_legacy_bound() {
	mut s := fixture()
	s.session = session_default
	s.dids[0].len = max_did_data
	s.dids[1].len = 2
	assert call(mut s, [u8(0x22), 0xF1, 0x90]).len == legacy_resp_cap
	assert call(mut s, [u8(0x22), 0xF1, 0x90, 0xF1, 0xAA]) == [u8(0x7F), 0x22, 0x14]
}

fn call_functional(mut s Server, req []u8) []u8 {
	mut resp := [256]u8{}
	n := s.handle_functional(&req[0], req.len, &resp[0])
	mut out := []u8{}
	for i in 0 .. n {
		out << resp[i]
	}
	return out
}

// REQ-DIAG-006: a functional request never answers 0x11/0x12/0x31/0x7E/0x7F, but other negative
// responses and positive responses still go out.
fn test_functional_requests_stay_silent_on_the_suppressed_nrcs() {
	mut s := started()
	assert call_functional(mut s, [u8(0x19), 0x02]).len == 0 // 0x11
	assert call_functional(mut s, [u8(0x3E), 0x05]).len == 0 // 0x12
	assert call_functional(mut s, [u8(0x22), 0x00, 0x01]).len == 0 // 0x31
	assert call_functional(mut s, [u8(0x28), 0x00, 0x01]).len == 0 // 0x7F (default session)
	assert call_functional(mut s, [u8(0x22), 0xF1]) == [u8(0x7F), 0x22, 0x13] // not suppressed
	assert call_functional(mut s, [u8(0x3E), 0x00]) == [u8(0x7E), 0x00]
	assert call_functional(mut s, [u8(0x3E), 0x80]).len == 0 // suppressPosRsp still applies
}

// REQ-DIAG-007: 0x11 records the reset for the owner and answers first.
fn test_ecu_reset_is_recorded_not_performed() {
	mut s := started()
	assert call(mut s, [u8(0x11), 0x01]) == [u8(0x51), 0x01]
	assert s.reset_req == 0x01
	assert call(mut s, [u8(0x11), 0x02]) == [u8(0x7F), 0x11, 0x12] // keyOffOn: not supported
	s.reset_state()
	assert s.reset_req == 0 && s.session == session_default
	assert call(mut s, [u8(0x11), 0x83]).len == 0 // soft reset, response suppressed
	assert s.reset_req == 0x03
}

// REQ-DIAG-007: 0x28 per communication type, "this network" always, "all networks" only on a
// single-network node.
fn test_communication_control() {
	mut s := started()
	call(mut s, [u8(0x10), 0x03])
	assert call(mut s, [u8(0x28), 0x01, 0xF1]) == [u8(0x68), 0x01] // this network: tx off
	assert !s.tx_enabled() && s.rx_enabled()
	assert call(mut s, [u8(0x28), 0x00, 0x01]) == [u8(0x7F), 0x28, 0x31] // all networks, multi
	s.single_network = true
	assert call(mut s, [u8(0x28), 0x00, 0x01]) == [u8(0x68), 0x00]
	assert s.tx_enabled() && s.rx_enabled()
	// NM (2) and normal+NM (3) are refused until NM is gated by 0x28 — no acknowledging a
	// silence that never happens
	assert call(mut s, [u8(0x28), 0x03, 0x02]) == [u8(0x7F), 0x28, 0x31]
	assert call(mut s, [u8(0x28), 0x03, 0x03]) == [u8(0x7F), 0x28, 0x31]
	assert s.tx_enabled()
	assert call(mut s, [u8(0x28), 0x00, 0x05]) == [u8(0x7F), 0x28, 0x31] // reserved type bits
}

// A request handled when the owner's clock reads 0 still starts S3 — 0 is a valid time.
fn test_s3_runs_from_a_request_at_time_zero() {
	mut s := started()
	s.tick(0)
	assert call(mut s, [u8(0x10), 0x03])[0] == 0x50
	s.tick(default_s3_us + 1)
	assert s.session == session_default, 'a request at t=0 left S3 unarmed'
}

// 0x2E follows its own ISO flow: security is checked before the record length.
fn test_write_security_precedes_record_length() {
	mut s := started()
	s.dids[1].write_security = 1
	mut long := [u8(0x2E), 0xF1, 0xAA]
	for _ in 0 .. max_did_data + 1 {
		long << 0x55
	}
	assert call(mut s, long) == [u8(0x7F), 0x2E, 0x33]
}

// A response buffer too small for the fixed responses: the server stays silent rather than
// write past it (every response, not only multi-DID reads, is bounded).
fn test_a_too_small_buffer_silences_the_server() {
	mut s := fixture()
	s.init(min_resp_cap - 1)
	assert call(mut s, [u8(0x10), 0x03]).len == 0
	assert call(mut s, [u8(0x19)]).len == 0
	s.init(min_resp_cap)
	assert call(mut s, [u8(0x10), 0x03]).len == 6
}

// A request accepted now and served later still keeps the session alive.
fn test_note_request_keeps_s3_alive() {
	mut s := started()
	s.tick(1_000_000)
	call(mut s, [u8(0x10), 0x03])
	s.tick(1_000_000 + default_s3_us - 1)
	s.note_request()
	s.tick(1_000_000 + default_s3_us + 10)
	assert s.session == session_extended
}

// A queued functional request keeps its ARRIVAL time: serving it later does not stretch S3.
fn test_a_queued_functional_request_keeps_its_arrival_time() {
	mut s := started()
	s.tick(1_000_000)
	call(mut s, [u8(0x10), 0x03])
	s.tick(2_000_000)
	s.note_request() // a functional TesterPresent arrives and is queued
	s.tick(2_000_000 + default_s3_us - 10) // served much later, still inside S3 of its arrival
	mut resp := [16]u8{}
	req := [u8(0x3E), 0x00]
	assert s.handle_functional_noted(&req[0], 2, &resp[0]) == 2
	s.tick(2_000_000 + default_s3_us + 1)
	assert s.session == session_default, 'serving a queued request re-stamped S3'
}
