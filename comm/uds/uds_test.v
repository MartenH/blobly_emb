module uds

// @verifies SYS-REQ-DIAG-001

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
	// 0xF190 is not writable -> conditionsNotCorrect
	assert call(mut s, [u8(0x2E), 0xF1, 0x90, 0x00]) == [u8(0x7F), 0x2E, 0x22]
}

fn test_unknown_service_rejected() {
	mut s := fixture()
	assert call(mut s, [u8(0x33), 0x00]) == [u8(0x7F), 0x33, 0x11]
}
