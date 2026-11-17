module doip

// Host-run DoIP framing tests (sim-first): the same bytes the H735 will see over
// TCP, without hardware. @verifies REQ-NET-007 (framing + the uds.Server reuse).
// The entity half (routing-activation policy, alive check, entity status, power mode) is in
// entity_test.v.

// the sizes of a server bound at the default maximum message length, as the tests use them
const max_uds = 520
const max_msg = header_len + 4 + max_uds
const max_resp = header_len + 5 + header_len + 4 + max_uds

// new_server: a server bound to an assembly buffer of its own at max_uds
fn new_server() Server {
	return server_at(max_uds)
}

// server_at: a server whose UDS messages are at most `m` bytes, its buffer the owner's
fn server_at(m int) Server {
	mut s := Server{}
	buf := []u8{len: msg_len(m)}
	s.bind(&buf[0], m)
	return s
}

// build a DoIP frame into dst; returns total length
fn frame(dst &u8, ptype u16, payload []u8) int {
	unsafe {
		dst[0] = 0x02
		dst[1] = 0xFD
		dst[2] = u8(ptype >> 8)
		dst[3] = u8(ptype)
		dst[4] = u8(payload.len >> 24)
		dst[5] = u8(payload.len >> 16)
		dst[6] = u8(payload.len >> 8)
		dst[7] = u8(payload.len)
		for i in 0 .. payload.len {
			dst[8 + i] = payload[i]
		}
	}
	return 8 + payload.len
}

// feed_in_room: `bytes` fed the way the transport feeds them — never more than the assembly
// buffer can still take (doipnet.pass) — and the response bytes they produce
fn feed_in_room(mut s Server, bytes []u8, resp_max int) []u8 {
	mut out := []u8{}
	mut resp := []u8{len: resp_max}
	mut at := 0
	for at < bytes.len {
		room := s.msg_cap() - s.buf_len
		take := if bytes.len - at < room { bytes.len - at } else { room }
		mut n := s.feed(unsafe { &bytes[at] }, take, unsafe { &resp[0] }, resp_max)
		for n > 0 {
			out << resp[..n]
			n = s.feed(unsafe { &bytes[0] }, 0, unsafe { &resp[0] }, resp_max)
		}
		at += take
	}
	return out
}

fn test_routing_activation_then_diag_roundtrip() {
	mut s := new_server()
	s.entity_addr = 0x0E80
	s.uds.session = 0x01
	// one DID: 0xF190 = "H735"
	s.uds.dids[0].id = 0xF190
	s.uds.dids[0].data[0] = `H`
	s.uds.dids[0].data[1] = `7`
	s.uds.dids[0].data[2] = `3`
	s.uds.dids[0].data[3] = `5`
	s.uds.dids[0].len = 4
	s.uds.ndid = 1

	mut inb := [max_msg]u8{}
	mut resp := [max_msg]u8{}

	// 1. routing activation from tester 0x0E00
	n := frame(&inb[0], 0x0005, [u8(0x0E), 0x00, 0x00, 0, 0, 0, 0])
	mut rlen := s.feed(&inb[0], n, &resp[0], max_msg)
	assert rlen == 8 + 9
	assert resp[2] == 0x00 && resp[3] == 0x06 // routing activation response
	assert resp[12] == 0x10 // success code
	assert s.activated
	assert s.tester_addr == 0x0E00

	// 2. diagnostic message: UDS 0x22 F190
	n2 := frame(&inb[0], 0x8001, [u8(0x0E), 0x00, 0x0E, 0x80, 0x22, 0xF1, 0x90])
	rlen = s.feed(&inb[0], n2, &resp[0], max_msg)
	// ack (8+5) then diag response (8+4+ (0x62 F1 90 'H735' = 7))
	assert rlen == 13 + 8 + 4 + 7
	assert resp[2] == 0x80 && resp[3] == 0x02 // positive ack first
	assert resp[12] == 0x00
	assert resp[13 + 2] == 0x80 && resp[13 + 3] == 0x01 // then a diag message
	uds_off := 13 + 8 + 4
	assert resp[uds_off] == 0x62 // 0x22 positive response
	assert resp[uds_off + 3] == `H`
	assert resp[uds_off + 6] == `5`
}

fn test_diag_before_activation_is_nacked() {
	mut s := new_server()
	s.entity_addr = 0x0E80
	mut inb := [max_msg]u8{}
	mut resp := [max_msg]u8{}
	n := frame(&inb[0], 0x8001, [u8(0x0E), 0x00, 0x0E, 0x80, 0x3E, 0x00])
	rlen := s.feed(&inb[0], n, &resp[0], max_msg)
	assert rlen == 8 + 5
	assert resp[2] == 0x80 && resp[3] == 0x03 // diag NACK
	assert resp[12] == 0x02 // invalid source (not activated)
}

fn test_fragmented_feed_across_chunks() {
	mut s := new_server()
	s.entity_addr = 0x0E80
	mut inb := [max_msg]u8{}
	mut resp := [max_msg]u8{}
	n := frame(&inb[0], 0x0005, [u8(0x0E), 0x00, 0x00, 0, 0, 0, 0])
	// feed byte-by-byte: nothing until the last byte completes the message
	mut rlen := 0
	for i in 0 .. n - 1 {
		rlen = s.feed(unsafe { &inb[i] }, 1, &resp[0], max_msg)
		assert rlen == 0
	}
	rlen = s.feed(unsafe { &inb[n - 1] }, 1, &resp[0], max_msg)
	assert rlen == 17
	assert s.activated
}

fn test_two_messages_in_one_chunk() {
	mut s := new_server()
	s.entity_addr = 0x0E80
	s.uds.session = 0x01
	mut inb := [max_msg]u8{}
	mut resp := [max_msg]u8{}
	n1 := frame(&inb[0], 0x0005, [u8(0x0E), 0x00, 0x00, 0, 0, 0, 0])
	n2 := frame(unsafe { &inb[n1] }, 0x8001, [u8(0x0E), 0x00, 0x0E, 0x80, 0x3E, 0x00])
	rlen := s.feed(&inb[0], n1 + n2, &resp[0], max_msg)
	// routing resp (17) + ack (13) + tester-present resp 0x7E 0x00 (8+4+2)
	assert rlen == 17 + 13 + 14
	assert resp[2] == 0x00 && resp[3] == 0x06
	assert resp[17 + 2] == 0x80 && resp[17 + 3] == 0x02
	assert resp[17 + 13 + 2] == 0x80 && resp[17 + 13 + 3] == 0x01
	assert resp[17 + 13 + 12] == 0x7E // TesterPresent positive
}

fn test_bad_pattern_nacks_and_resets() {
	mut s := new_server()
	mut inb := [max_msg]u8{}
	mut resp := [max_msg]u8{}
	inb[0] = 0x03 // wrong version
	inb[1] = 0xFD
	rlen := s.feed(&inb[0], 8, &resp[0], max_msg)
	assert rlen == 9
	assert resp[2] == 0x00 && resp[3] == 0x00 // generic NACK
	assert resp[8] == 0x00 // incorrect pattern
	assert s.buf_len == 0
	assert s.fatal // stream is desynced: the transport must drop the connection
}

fn test_unsupported_activation_type_rejected() {
	mut s := new_server()
	s.entity_addr = 0x0E80
	mut inb := [max_msg]u8{}
	mut resp := [max_msg]u8{}
	n := frame(&inb[0], 0x0005, [u8(0x0E), 0x00, 0xE0, 0, 0, 0, 0]) // OEM type
	rlen := s.feed(&inb[0], n, &resp[0], max_msg)
	assert rlen == 17
	assert resp[2] == 0x00 && resp[3] == 0x06
	assert resp[12] == 0x06 // unsupported routing activation type
	assert !s.activated
}

fn test_vehicle_ident_requests() {
	mut s := new_server()
	s.entity_addr = 0x0E80
	vin := 'BLOBLY0TESTVIN001'
	for i in 0 .. 17 {
		s.vin[i] = vin[i]
	}
	eid := [u8(0x02), 0xAA, 0xBB, 0xCC, 0xDD, 0xEE]
	mut req := [64]u8{}
	mut resp := [64]u8{}
	// 0x0001 (any): answered with the announcement
	n := frame(&req[0], 0x0001, []u8{})
	assert s.udp_response(&req[0], n, &eid[0], 0, &resp[0]) == 40
	assert resp[2] == 0x00 && resp[3] == 0x04
	// 0x0003 by VIN: match answers, mismatch is silence
	mut vp := []u8{len: 17}
	for i in 0 .. 17 {
		vp[i] = vin[i]
	}
	n2 := frame(&req[0], 0x0003, vp)
	assert s.udp_response(&req[0], n2, &eid[0], 0, &resp[0]) == 40
	req[8] = `X`
	assert s.udp_response(&req[0], n2, &eid[0], 0, &resp[0]) == 0
	// 0x0002 by EID: mismatch is silence
	n3 := frame(&req[0], 0x0002, [u8(9), 9, 9, 9, 9, 9])
	assert s.udp_response(&req[0], n3, &eid[0], 0, &resp[0]) == 0
	// truncated / non-ident types: silence
	assert s.udp_response(&req[0], 4, &eid[0], 0, &resp[0]) == 0
}

fn test_unknown_type_nacks() {
	mut s := new_server()
	mut inb := [max_msg]u8{}
	mut resp := [max_msg]u8{}
	n := frame(&inb[0], 0x4005, []u8{}) // not a payload type this entity serves
	rlen := s.feed(&inb[0], n, &resp[0], max_msg)
	assert rlen == 9
	assert resp[8] == 0x01 // unknown payload type
}

fn test_high_bit_length_nacks_not_wraps() {
	// plen 0x80000000 narrowed to int is negative; the u32 bound must catch it
	// before the shift loop runs off the buffer
	mut s := new_server()
	mut inb := [max_msg]u8{}
	mut resp := [max_msg]u8{}
	inb[0] = 0x02
	inb[1] = 0xFD
	inb[2] = 0x80
	inb[3] = 0x01
	inb[4] = 0x80 // plen = 0x80000000
	rlen := s.feed(&inb[0], 8, &resp[0], max_msg)
	assert rlen == 9
	assert resp[8] == 0x02 // too large
	assert s.buf_len == 0
}

fn test_full_resp_buffer_retains_message() {
	// no room for even one worst-case response: the message must stay buffered
	// (not be silently consumed) and drain on a later len-0 feed
	mut s := new_server()
	s.entity_addr = 0x0E80
	mut inb := [max_msg]u8{}
	mut resp := [max_msg]u8{}
	n := frame(&inb[0], 0x0005, [u8(0x0E), 0x00, 0x00, 0, 0, 0, 0])
	mut rlen := s.feed(&inb[0], n, &resp[0], 16)
	assert rlen == 0
	assert !s.activated
	assert s.buf_len == n
	rlen = s.feed(&inb[0], 0, &resp[0], max_msg)
	assert rlen == 17
	assert s.activated
}

fn test_dataless_diag_nacks_no_silent_ack() {
	// plen 4 = addresses only, no UDS byte: must NACK, not ack-then-nothing
	mut s := new_server()
	s.entity_addr = 0x0E80
	mut inb := [max_msg]u8{}
	mut resp := [max_msg]u8{}
	n := frame(&inb[0], 0x0005, [u8(0x0E), 0x00, 0x00, 0, 0, 0, 0])
	mut rlen := s.feed(&inb[0], n, &resp[0], max_msg)
	assert s.activated
	n2 := frame(&inb[0], 0x8001, [u8(0x0E), 0x00, 0x0E, 0x80])
	rlen = s.feed(&inb[0], n2, &resp[0], max_msg)
	assert rlen == 9
	assert resp[2] == 0x00 && resp[3] == 0x00 // generic NACK
	assert resp[8] == 0x04 // invalid payload length
}

fn test_tiny_resp_buffer_never_written() {
	// resp_max below even a NACK: feed must not write a single byte
	mut s := new_server()
	mut inb := [max_msg]u8{}
	mut resp := [max_msg]u8{}
	resp[0] = 0xAA
	inb[0] = 0x03 // wrong version -> would NACK
	inb[1] = 0xFD
	rlen := s.feed(&inb[0], 8, &resp[0], 4)
	assert rlen == 0
	assert resp[0] == 0xAA // untouched
	assert s.buf_len == 0 // stream state still reset
}

fn test_routing_length_must_be_exact() {
	// 8-byte payload is neither 7 (plain) nor 11 (with OEM): NACK, no activation
	mut s := new_server()
	s.entity_addr = 0x0E80
	mut inb := [max_msg]u8{}
	mut resp := [max_msg]u8{}
	n := frame(&inb[0], 0x0005, [u8(0x0E), 0x00, 0x00, 0, 0, 0, 0, 0xAA])
	rlen := s.feed(&inb[0], n, &resp[0], max_msg)
	assert rlen == 9
	assert resp[8] == 0x04 // invalid payload length
	assert !s.activated
	assert s.fatal // the header handler closes the socket after an invalid length
}

fn test_ident_accepts_generic_version() {
	// discovery may use the generic 0xFF/0x00 pattern (tester doesn't yet know
	// the entity's DoIP revision); the response still carries version 0x02
	mut s := new_server()
	s.entity_addr = 0x0E80
	eid := [u8(0x02), 0xAA, 0xBB, 0xCC, 0xDD, 0xEE]
	mut req := [64]u8{}
	mut resp := [64]u8{}
	req[0] = 0xFF
	req[1] = 0x00
	req[2] = 0x00
	req[3] = 0x01 // vehicle identification request, plen 0
	assert s.udp_response(&req[0], 8, &eid[0], 0, &resp[0]) == 40
	assert resp[0] == 0x02 && resp[1] == 0xFD
}

fn test_announcement_layout() {
	mut s := new_server()
	s.entity_addr = 0x0E80
	vin := 'BLOBLY0TESTVIN001'
	for i in 0 .. 17 {
		s.vin[i] = vin[i]
	}
	eid := [u8(0x02), 0xAA, 0xBB, 0xCC, 0xDD, 0xEE]
	mut resp := [max_msg]u8{}
	n := s.announcement(&eid[0], &resp[0])
	assert n == 8 + 32
	assert resp[2] == 0x00 && resp[3] == 0x04
	assert resp[8] == `B` && resp[24] == `1` // VIN start/end
	assert resp[25] == 0x0E && resp[26] == 0x80
	assert resp[27] == 0x02 && resp[32] == 0xEE // EID
	assert resp[33] == 0x02 // GID = EID
	assert resp[39] == 0x00 // further action
}

// what the external server saw last (serve hook tests)
__global g_seen_len int
__global g_seen_functional bool

// answers 0x22 with 300 bytes (more than the embedded server ever could) and
// 0x3E 80 with nothing, like a suppressed positive response
fn serve_big(_ voidptr, req &u8, req_len int, functional bool, resp &u8, resp_cap int) int {
	assert resp_cap == max_uds
	g_seen_len = req_len
	g_seen_functional = functional
	if unsafe { req[0] } == 0x3E {
		return 0
	}
	unsafe {
		resp[0] = 0x62
		for i in 1 .. 300 {
			resp[i] = u8(i)
		}
	}
	return 300
}

fn activated_with(answer fn (voidptr, &u8, int, bool, &u8, int) int) Server {
	mut s := new_server()
	s.entity_addr = 0x0E80
	s.serve.answer = answer
	mut inb := [max_msg]u8{}
	mut resp := [1024]u8{}
	n := frame(&inb[0], 0x0005, [u8(0x0E), 0x00, 0x00, 0, 0, 0, 0])
	assert s.feed(&inb[0], n, &resp[0], resp.len) == 8 + 9
	return s
}

fn test_serve_hook_answers_with_a_full_iso_tp_response() {
	mut s := activated_with(serve_big)
	mut inb := [max_msg]u8{}
	mut resp := [1024]u8{}
	n := frame(&inb[0], 0x8001, [u8(0x0E), 0x00, 0x0E, 0x80, 0x22, 0xF1, 0x90])
	rlen := s.feed(&inb[0], n, &resp[0], resp.len)
	assert g_seen_len == 3 && !g_seen_functional
	assert rlen == 13 + 8 + 4 + 300
	assert resp[13 + 4] == 0 && resp[13 + 5] == 0 && resp[13 + 6] == 0x01 && resp[13 + 7] == 0x30
	assert resp[13 + 12] == 0x62
	assert resp[13 + 12 + 299] == u8(299 & 0xFF)
}

fn test_functional_target_reaches_the_server_as_functional() {
	mut s := activated_with(serve_big)
	mut inb := [max_msg]u8{}
	mut resp := [1024]u8{}
	// 0x3E 80 to the functional address: acked, answered by nothing
	n := frame(&inb[0], 0x8001, [u8(0x0E), 0x00, 0xE4, 0x00, 0x3E, 0x80])
	rlen := s.feed(&inb[0], n, &resp[0], resp.len)
	assert g_seen_functional
	assert rlen == 13
	assert resp[2] == 0x80 && resp[3] == 0x02 && resp[12] == 0x00
	// the ack comes from the address the request was sent to
	assert resp[8] == 0xE4 && resp[9] == 0x00
}

fn test_embedded_server_withholds_functional_negatives() {
	mut s := activated_with(unsafe { nil })
	s.uds.session = 0x01
	mut inb := [max_msg]u8{}
	mut resp := [max_msg]u8{}
	// an unsupported service: physical gets 7F xx 11, functional gets nothing
	n := frame(&inb[0], 0x8001, [u8(0x0E), 0x00, 0x0E, 0x80, 0xBA])
	assert s.feed(&inb[0], n, &resp[0], max_msg) == 13 + 8 + 4 + 3
	assert resp[13 + 12] == 0x7F && resp[13 + 14] == 0x11
	n2 := frame(&inb[0], 0x8001, [u8(0x0E), 0x00, 0xE4, 0x00, 0xBA])
	assert s.feed(&inb[0], n2, &resp[0], max_msg) == 13
}

fn test_serve_hook_needs_room_for_its_largest_response() {
	mut s := activated_with(serve_big)
	mut inb := [max_msg]u8{}
	mut resp := [1024]u8{}
	n := frame(&inb[0], 0x8001, [u8(0x0E), 0x00, 0x0E, 0x80, 0x22, 0xF1, 0x90])
	// a buffer below max_resp_per_msg keeps the message buffered, unserved
	assert s.feed(&inb[0], n, &resp[0], s.max_resp_per_msg() - 1) == 0
	assert s.buf_len == n
	assert s.feed(&inb[0], 0, &resp[0], s.max_resp_per_msg()) == 13 + 8 + 4 + 300
}

// claims a longer response than it was allowed
fn serve_overlong(_ voidptr, _ &u8, _ int, _ bool, _ &u8, resp_cap int) int {
	return resp_cap + 1
}

fn test_overlong_answer_is_nacked_not_framed() {
	mut s := activated_with(serve_overlong)
	mut inb := [max_msg]u8{}
	mut resp := [1024]u8{}
	n := frame(&inb[0], 0x8001, [u8(0x0E), 0x00, 0x0E, 0x80, 0x22, 0xF1, 0x90])
	assert s.feed(&inb[0], n, &resp[0], resp.len) == 13
	assert resp[2] == 0x80 && resp[3] == 0x03 && resp[12] == 0x08
}

fn test_embedded_server_answers_within_its_init_capacity() {
	mut s := new_server()
	s.uds.init(100)
	assert s.max_resp_per_msg() == 13 + 12 + 100
	s.functional_addr = 0xE401
	mut inb := [max_msg]u8{}
	mut resp := [1024]u8{}
	n := frame(&inb[0], 0x0005, [u8(0x0E), 0x00, 0x00, 0, 0, 0, 0])
	assert s.feed(&inb[0], n, &resp[0], resp.len) == 17
	// a configured functional address replaces the default one
	n2 := frame(&inb[0], 0x8001, [u8(0x0E), 0x00, 0xE4, 0x01, 0x3E, 0x80])
	assert s.feed(&inb[0], n2, &resp[0], resp.len) == 13
	n3 := frame(&inb[0], 0x8001, [u8(0x0E), 0x00, 0xE4, 0x00, 0x3E, 0x80])
	assert s.feed(&inb[0], n3, &resp[0], resp.len) == 13
	assert resp[3] == 0x03 && resp[12] == 0x03 // unknown target
}

// @verifies REQ-CAN-TP-023
// an embedded server on an entity bound at 8 answers within that limit: fed through a response
// buffer of resp_cap(), the activation and a request are served (its legacy capacity of 35 had
// kept every message waiting), and a DID past the limit is refused with 0x14 — whether its
// own init came before bind or after
fn test_embedded_server_follows_the_bound_limit() {
	for init_first in [false, true] {
		mut s := Server{}
		if init_first {
			s.uds.init(100)
		}
		buf := []u8{len: msg_len(8)}
		s.bind(&buf[0], 8)
		s.entity_addr = 0x0E80
		s.uds.session = 0x01
		s.uds.dids[0].id = 0xF190
		s.uds.dids[0].len = 4
		s.uds.dids[1].id = 0xF191
		s.uds.dids[1].len = 8
		s.uds.ndid = 2
		assert s.max_resp_per_msg() <= s.resp_cap()
		mut bytes := [64]u8{}
		n := frame(&bytes[0], 0x0005, [u8(0x0E), 0x00, 0x00, 0, 0, 0, 0])
		got := feed_in_room(mut s, bytes[..n], s.resp_cap())
		assert got.len == 17 && got[12] == 0x10
		n2 := frame(&bytes[0], 0x8001, [u8(0x0E), 0x00, 0x0E, 0x80, 0x22, 0xF1, 0x90])
		ok := feed_in_room(mut s, bytes[..n2], s.resp_cap())
		assert ok.len == 13 + 12 + 7 && ok[25] == 0x62
		n3 := frame(&bytes[0], 0x8001, [u8(0x0E), 0x00, 0x0E, 0x80, 0x22, 0xF1, 0x91])
		long := feed_in_room(mut s, bytes[..n3], s.resp_cap())
		assert long.len == 13 + 12 + 3 && long[25..] == [u8(0x7F), 0x22, 0x14]
	}
}

fn test_max_resp_is_a_hook_servers_room() {
	mut s := new_server()
	s.serve.answer = serve_big
	assert s.max_resp_per_msg() == max_resp
}

// a request as large as one ISO-TP message — a bootloader's TransferData block — reaches the
// server whole, and one byte more is too large: the DoIP binding takes what the CAN one takes
fn test_largest_request_is_one_isotp_message() {
	mut s := activated_with(serve_big)
	mut inb := [max_msg + 1]u8{}
	mut resp := [1024]u8{}
	mut req := [u8(0x0E), 0x00, 0x0E, 0x80, 0x36, 0x01]
	for req.len < 4 + max_uds {
		req << u8(req.len)
	}
	n := frame(&inb[0], 0x8001, req)
	assert n == max_msg
	assert s.feed(&inb[0], n, &resp[0], resp.len) == 13 + 8 + 4 + 300
	assert g_seen_len == max_uds
	mut s2 := activated_with(serve_big)
	req << 0
	n2 := frame(&inb[0], 0x8001, req)
	got := feed_in_room(mut s2, inb[..n2], resp.len)
	assert got.len == 9 // generic NACK: message too large, the message discarded
	assert got[2] == 0x00 && got[3] == 0x00 && got[8] == 0x02
	assert !s2.fatal && s2.buf_len == 0 && s2.skip == 0
}

// a further response (a routine's next responsePending, its answer) goes to the activated tester
// as a diagnostic message from this entity
fn test_a_further_response_is_a_diagnostic_message_to_the_tester() {
	s := activated_with(serve_big)
	mut out := [64]u8{}
	uds := [u8(0x7F), 0x31, 0x78]
	n := s.response_message(&uds[0], 3, &out[0])
	assert out[..n] == [u8(0x02), 0xFD, 0x80, 0x01, 0, 0, 0, 7, 0x0E, 0x80, 0x0E, 0x00, 0x7F, 0x31,
		0x78]
}

__global g_hook_cap int

// answers a request with its positive service byte alone, recording its length and the room given
fn serve_echo(_ voidptr, req &u8, req_len int, _ bool, resp &u8, resp_cap int) int {
	g_hook_cap = resp_cap
	g_seen_len = req_len
	unsafe {
		resp[0] = req[0] + 0x40
	}
	return 1
}

// an activated server of maximum message `m` answering through serve_echo
fn activated_at(m int) Server {
	mut s := server_at(m)
	s.entity_addr = 0x0E80
	s.serve.answer = serve_echo
	inb := []u8{len: 64}
	resp := []u8{len: s.resp_cap()}
	n := frame(&inb[0], 0x0005, [u8(0x0E), 0x00, 0x00, 0, 0, 0, 0])
	assert s.feed(&inb[0], n, &resp[0], resp.len) == 8 + 9
	return s
}

// a diagnostic message from the tester to the entity carrying `n` UDS bytes
fn diag_msg(n int) []u8 {
	mut payload := [u8(0x0E), 0x00, 0x0E, 0x80, 0x36]
	for payload.len < 4 + n {
		payload << u8(payload.len)
	}
	mut out := []u8{len: header_len + payload.len}
	frame(unsafe { &out[0] }, 0x8001, payload)
	return out
}

// @verifies REQ-CAN-TP-023
// the entity's UDS limit is the node's maximum message: a 4095-byte request reaches the server at
// 4095 (with 4095 bytes of answer room), and at the default it is too large — the generic NACK
// 0x02, the message discarded, and the connection kept: the next request is answered
fn test_the_uds_limit_follows_the_maximum_message() {
	mut s := activated_at(4095)
	assert s.msg_cap() == msg_len(4095) && s.resp_cap() == resp_len(4095)
	msg := diag_msg(4095)
	resp := []u8{len: s.resp_cap()}
	assert s.feed(&msg[0], msg.len, &resp[0], resp.len) == 13 + 8 + 4 + 1
	assert g_seen_len == 4095 && g_hook_cap == 4095 && !s.fatal
	mut d := activated_at(520)
	got := feed_in_room(mut d, msg, d.resp_cap())
	assert got.len == 9 && got[2] == 0x00 && got[3] == 0x00 && got[8] == 0x02 && !d.fatal
	g_seen_len = 0
	next := diag_msg(10)
	assert feed_in_room(mut d, next, d.resp_cap()).len == 13 + 8 + 4 + 1 && g_seen_len == 10
}

// @verifies REQ-CAN-TP-023
// entity status reports the maximum data size the node's maximum message gives: 4 + max_message
fn test_entity_status_reports_the_maximum_message() {
	for m in [520, 4095, 8] {
		mut s := server_at(m)
		inb := []u8{len: 16}
		resp := []u8{len: 64}
		n := frame(&inb[0], 0x4001, []u8{})
		assert s.feed(&inb[0], n, &resp[0], resp.len) == 8 + 7
		size := u32(resp[11]) << 24 | u32(resp[12]) << 16 | u32(resp[13]) << 8 | u32(resp[14])
		assert size == u32(4 + m), 'max_message ${m}'
	}
}

// a server nobody bound assembles nothing: the first bytes are too large, and nothing is buffered
fn test_an_unbound_server_refuses() {
	mut s := Server{}
	assert s.msg_cap() == 0
	inb := []u8{len: 16}
	resp := []u8{len: 64}
	n := frame(&inb[0], 0x0005, [u8(0x0E), 0x00, 0x00, 0, 0, 0, 0])
	assert s.feed(&inb[0], n, &resp[0], resp.len) == 9
	assert resp[8] == 0x02 && s.fatal && s.buf_len == 0
}
