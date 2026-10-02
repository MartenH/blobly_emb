module doip

// The DoIP entity at the transport level (ISO 13400-2:2012): the routing-activation policy and
// each of its outcomes, alive check, entity status and diagnostic power mode on TCP and UDP, and
// the configuration rules the generator and syscheck share (policy.v).
// @verifies REQ-NET-007 (the DoIP transport binding)

// build a DoIP frame into dst; returns total length (doip_test.v's, each test file is its own)
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

// one routing activation request from `sa` of activation type `atype` on s; the response stream
fn activate(mut s Server, sa u16, atype u8) []u8 {
	mut inb := [max_msg]u8{}
	mut resp := [max_msg]u8{}
	n := frame(&inb[0], 0x0005, [u8(sa >> 8), u8(sa), atype, 0, 0, 0, 0])
	rlen := s.feed(&inb[0], n, &resp[0], max_msg)
	return resp[..rlen].clone()
}

// the response code of a routing activation response (and that it is one, from s to sa)
fn ra_code(s Server, sa u16, r []u8) u8 {
	assert r.len == 8 + 9
	assert r[2] == 0x00 && r[3] == 0x06
	assert r[8] == u8(sa >> 8) && r[9] == u8(sa)
	assert r[10] == u8(s.entity_addr >> 8) && r[11] == u8(s.entity_addr)
	return r[12]
}

fn entity() Server {
	mut s := Server{}
	s.entity_addr = 0x07A0
	return s
}

fn test_default_policy_activates_any_tester_address() {
	for sa in [u16(0x0E00), 0x0E80, 0x0FFF] {
		mut s := entity()
		assert ra_code(s, sa, activate(mut s, sa, 0x00)) == 0x10
		assert s.activated && s.tester_addr == sa && !s.fatal
	}
}

// a source address outside the tester range is not a tester: refused, and the socket closes
fn test_a_source_outside_the_tester_range_is_unknown() {
	for sa in [u16(0x0001), 0x07A0, 0x0DFF, 0x1000, 0xE400] {
		mut s := entity()
		assert ra_code(s, sa, activate(mut s, sa, 0x00)) == 0x00
		assert !s.activated && s.fatal
	}
}

fn test_a_tester_list_admits_only_its_addresses() {
	mut s := entity()
	s.testers[0] = 0x0E80
	s.testers[1] = 0x0F00
	s.n_testers = 2
	assert ra_code(s, 0x0F00, activate(mut s, 0x0F00, 0x00)) == 0x10
	mut t := entity()
	t.testers[0] = 0x0E80
	t.n_testers = 1
	// in the tester range, but not listed
	assert ra_code(t, 0x0E00, activate(mut t, 0x0E00, 0x00)) == 0x00
	assert !t.activated && t.fatal
}

fn test_only_the_served_activation_types_activate() {
	// default: 0x00 only — WWH-OBD and the VM-specific types are refused, and the socket closes
	for atype in [u8(0x01), 0xE0, 0xE1, 0xFF] {
		mut s := entity()
		assert ra_code(s, 0x0E00, activate(mut s, 0x0E00, atype)) == 0x06
		assert !s.activated && s.fatal
	}
	// a configured list replaces the default one
	mut s := entity()
	s.act_types[0] = 0xE1
	s.n_act_types = 1
	assert ra_code(s, 0x0E00, activate(mut s, 0x0E00, 0x00)) == 0x06
	mut t := entity()
	t.act_types[0] = 0x00
	t.act_types[1] = 0xE1
	t.n_act_types = 2
	assert ra_code(t, 0x0E00, activate(mut t, 0x0E00, 0xE1)) == 0x10
	assert t.activated
}

// the source address is checked before the activation type
fn test_an_unknown_source_is_reported_before_an_unsupported_type() {
	mut s := entity()
	assert ra_code(s, 0x0001, activate(mut s, 0x0001, 0x01)) == 0x00
}

fn test_the_registered_source_may_activate_again_another_may_not() {
	mut s := entity()
	assert ra_code(s, 0x0E00, activate(mut s, 0x0E00, 0x00)) == 0x10
	assert ra_code(s, 0x0E00, activate(mut s, 0x0E00, 0x00)) == 0x10
	assert s.activated && !s.fatal
	// a different source address on this registered socket: refused, the socket closes
	assert ra_code(s, 0x0E01, activate(mut s, 0x0E01, 0x00)) == 0x02
	assert s.fatal && s.tester_addr == 0x0E00
}

// a refusal closes the socket: whatever arrived behind it in the same chunk is not served
fn test_nothing_is_served_after_a_refusal() {
	mut s := entity()
	s.uds.session = 0x01
	mut inb := [max_msg]u8{}
	mut resp := [max_msg]u8{}
	n1 := frame(&inb[0], 0x0005, [u8(0x00), 0x01, 0x00, 0, 0, 0, 0]) // not a tester
	n2 := frame(unsafe { &inb[n1] }, 0x8001, [u8(0x00), 0x01, 0x07, 0xA0, 0x3E, 0x00])
	rlen := s.feed(&inb[0], n1 + n2, &resp[0], max_msg)
	assert rlen == 17 && resp[12] == 0x00
	assert s.fatal && s.buf_len == 0
}

fn test_the_testers_alive_check_response_needs_no_reply() {
	mut s := entity()
	activate(mut s, 0x0E00, 0x00)
	mut inb := [max_msg]u8{}
	mut resp := [max_msg]u8{}
	n := frame(&inb[0], 0x0008, [u8(0x0E), 0x00])
	assert s.feed(&inb[0], n, &resp[0], max_msg) == 0
	assert s.buf_len == 0 && !s.fatal && s.activated
	// its payload is the source address, exactly
	n2 := frame(&inb[0], 0x0008, [u8(0x0E)])
	assert s.feed(&inb[0], n2, &resp[0], max_msg) == 9
	assert resp[3] == 0x00 && resp[8] == 0x04 // generic NACK: invalid payload length
	assert s.fatal // ...after which the socket closes
}

fn test_an_alive_check_request_is_answered_with_the_entity_address() {
	mut s := entity()
	mut inb := [max_msg]u8{}
	mut resp := [max_msg]u8{}
	n := frame(&inb[0], 0x0007, []u8{})
	assert s.feed(&inb[0], n, &resp[0], max_msg) == 10
	assert resp[2] == 0x00 && resp[3] == 0x08
	assert resp[7] == 2 && resp[8] == 0x07 && resp[9] == 0xA0
	n2 := frame(&inb[0], 0x0007, [u8(0)])
	assert s.feed(&inb[0], n2, &resp[0], max_msg) == 9
	assert resp[8] == 0x04
}

// node type, max sockets, open sockets, max data size
fn check_status(r []u8, open u8) {
	assert r.len == 8 + 7
	assert r[2] == 0x40 && r[3] == 0x02 && r[7] == 7
	assert r[8] == 0x01 // a DoIP node, not a gateway
	assert r[9] == 1 // one TCP_DATA socket
	assert r[10] == open
	assert r[11] == 0 && r[12] == 0 && r[13] == 0 && r[14] == u8(max_msg - 8)
}

fn test_entity_status_and_power_mode_over_tcp() {
	mut s := entity()
	mut inb := [max_msg]u8{}
	mut resp := [max_msg]u8{}
	n := frame(&inb[0], 0x4001, []u8{})
	rlen := s.feed(&inb[0], n, &resp[0], max_msg)
	check_status(resp[..rlen].clone(), 1) // the asker's own connection is the one open
	n2 := frame(&inb[0], 0x4003, []u8{})
	assert s.feed(&inb[0], n2, &resp[0], max_msg) == 9
	assert resp[2] == 0x40 && resp[3] == 0x04 && resp[8] == 0x01 // ready
	n3 := frame(&inb[0], 0x4003, [u8(1)])
	assert s.feed(&inb[0], n3, &resp[0], max_msg) == 9
	assert resp[3] == 0x00 && resp[8] == 0x04
}

fn test_entity_status_and_power_mode_over_udp() {
	s := entity()
	eid := [u8(0x02), 0xAA, 0xBB, 0xCC, 0xDD, 0xEE]
	mut req := [64]u8{}
	mut resp := [64]u8{}
	n := frame(&req[0], 0x4001, []u8{})
	for open in [0, 1] {
		rlen := s.udp_response(&req[0], n, &eid[0], open, &resp[0])
		check_status(resp[..rlen].clone(), u8(open))
	}
	n2 := frame(&req[0], 0x4003, []u8{})
	assert s.udp_response(&req[0], n2, &eid[0], 0, &resp[0]) == 9
	assert resp[3] == 0x04 && resp[8] == 0x01
	// malformed: silence, as for identification
	n3 := frame(&req[0], 0x4001, [u8(0)])
	assert s.udp_response(&req[0], n3, &eid[0], 0, &resp[0]) == 0
	// the generic version pattern is identification's alone
	n4 := frame(&req[0], 0x4001, []u8{})
	req[0] = 0xFF
	req[1] = 0x00
	assert s.udp_response(&req[0], n4, &eid[0], 0, &resp[0]) == 0
	// and what only TCP carries is silence on UDP
	n5 := frame(&req[0], 0x0005, [u8(0x0E), 0x00, 0x00, 0, 0, 0, 0])
	assert s.udp_response(&req[0], n5, &eid[0], 0, &resp[0]) == 0
}

fn test_the_configuration_rules() {
	assert tester_address_ok(0x0E00) && tester_address_ok(0x0FFF)
	assert !tester_address_ok(0x0DFF) && !tester_address_ok(0x1000)
	for t in [i64(0x00), 0x01, 0xE1, 0xFF] {
		assert activation_type_ok(t), t.hex()
	}
	// reserved, central security (not implemented), and not a byte
	for t in [i64(0x02), 0xDF, 0xE0, 0x100, -1] {
		assert !activation_type_ok(t), t.hex()
	}
	assert timers_ok(initial_inactivity_ms, general_inactivity_ms)
	assert timers_ok(100, 1000) && timers_ok(60000, 3600000)
	assert !timers_ok(99, 300000) && !timers_ok(2000, 3600001)
	assert !timers_ok(5000, 4000) // longer to activate than to idle
	assert announce_ok(announce_count, announce_interval_ms) && announce_ok(0, 500)
	assert !announce_ok(-1, 500) && !announce_ok(11, 500) && !announce_ok(3, 9)
	assert !announce_ok(3, 10001)
	assert announce_ok(10, 1000) && !announce_ok(2, 6000) // the whole sequence, 10 s at most
}
