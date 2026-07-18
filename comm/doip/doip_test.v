module doip

// Host-run DoIP framing tests (sim-first): the same bytes the H735 will see over
// TCP, without hardware. @verifies REQ-NET-007 (framing + the uds.Server reuse).

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

fn test_routing_activation_then_diag_roundtrip() {
	mut s := Server{}
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
	mut s := Server{}
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
	mut s := Server{}
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
	mut s := Server{}
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
	mut s := Server{}
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
	mut s := Server{}
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
	mut s := Server{}
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
	assert s.ident_response(&req[0], n, &eid[0], &resp[0]) == 40
	assert resp[2] == 0x00 && resp[3] == 0x04
	// 0x0003 by VIN: match answers, mismatch is silence
	mut vp := []u8{len: 17}
	for i in 0 .. 17 {
		vp[i] = vin[i]
	}
	n2 := frame(&req[0], 0x0003, vp)
	assert s.ident_response(&req[0], n2, &eid[0], &resp[0]) == 40
	req[8] = `X`
	assert s.ident_response(&req[0], n2, &eid[0], &resp[0]) == 0
	// 0x0002 by EID: mismatch is silence
	n3 := frame(&req[0], 0x0002, [u8(9), 9, 9, 9, 9, 9])
	assert s.ident_response(&req[0], n3, &eid[0], &resp[0]) == 0
	// truncated / non-ident types: silence
	assert s.ident_response(&req[0], 4, &eid[0], &resp[0]) == 0
}

fn test_unknown_type_nacks() {
	mut s := Server{}
	mut inb := [max_msg]u8{}
	mut resp := [max_msg]u8{}
	n := frame(&inb[0], 0x0007, [u8(0)]) // alive check: out of P3b scope
	rlen := s.feed(&inb[0], n, &resp[0], max_msg)
	assert rlen == 9
	assert resp[8] == 0x01 // unknown payload type
}

fn test_high_bit_length_nacks_not_wraps() {
	// plen 0x80000000 narrowed to int is negative; the u32 bound must catch it
	// before the shift loop runs off the buffer
	mut s := Server{}
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
	mut s := Server{}
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
	mut s := Server{}
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
	mut s := Server{}
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
	mut s := Server{}
	s.entity_addr = 0x0E80
	mut inb := [max_msg]u8{}
	mut resp := [max_msg]u8{}
	n := frame(&inb[0], 0x0005, [u8(0x0E), 0x00, 0x00, 0, 0, 0, 0, 0xAA])
	rlen := s.feed(&inb[0], n, &resp[0], max_msg)
	assert rlen == 9
	assert resp[8] == 0x04 // invalid payload length
	assert !s.activated
}

fn test_ident_accepts_generic_version() {
	// discovery may use the generic 0xFF/0x00 pattern (tester doesn't yet know
	// the entity's DoIP revision); the response still carries version 0x02
	mut s := Server{}
	s.entity_addr = 0x0E80
	eid := [u8(0x02), 0xAA, 0xBB, 0xCC, 0xDD, 0xEE]
	mut req := [64]u8{}
	mut resp := [64]u8{}
	req[0] = 0xFF
	req[1] = 0x00
	req[2] = 0x00
	req[3] = 0x01 // vehicle identification request, plen 0
	assert s.ident_response(&req[0], 8, &eid[0], &resp[0]) == 40
	assert resp[0] == 0x02 && resp[1] == 0xFD
}

fn test_announcement_layout() {
	mut s := Server{}
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
