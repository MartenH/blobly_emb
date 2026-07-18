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
