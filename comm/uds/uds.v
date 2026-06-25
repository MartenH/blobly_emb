module uds

// UDS (ISO 14229) server, no-alloc and transport-agnostic. It sits above ISO-TP:
// the bridge hands it a reassembled request and ships the response it produces.
// Table-driven so the protocol logic is shared + unit-tested; the example's DIDs
// (and any live-signal refresh) are filled in by the generated bridge.
//
// Supported services: 0x10 DiagnosticSessionControl, 0x22 ReadDataByIdentifier,
// 0x2E WriteDataByIdentifier, 0x3E TesterPresent. Anything else -> negative.

pub const max_dids = 16
pub const max_did_data = 32 // bytes stored per DID

// negative-response codes (NRC)
const nrc_service_not_supported = u8(0x11)
const nrc_incorrect_length = u8(0x13)
const nrc_conditions_not_correct = u8(0x22)
const nrc_request_out_of_range = u8(0x31)

// Did is one Data Identifier: constant bytes, a RAM cell (writable), and/or kept
// fresh from a live signal by the bridge.
pub struct Did {
pub mut:
	id       u16
	data     [max_did_data]u8
	len      u8
	writable bool
}

pub struct Server {
pub mut:
	session u8 = 0x01 // current diagnostic session (default)
	dids    [max_dids]Did
	ndid    int
}

// handle dispatches one UDS request (req[0..req_len]) and writes the response into
// resp, returning its length (0 = no response, e.g. suppressed).
pub fn (mut s Server) handle(req &u8, req_len int, resp &u8) int {
	if req_len < 1 {
		return 0
	}
	sid := unsafe { req[0] }
	match sid {
		0x3E { return s.tester_present(req, req_len, resp) }
		0x10 { return s.session_control(req, req_len, resp) }
		0x22 { return s.read_did(req, req_len, resp) }
		0x2E { return s.write_did(req, req_len, resp) }
		else { return negative(resp, sid, nrc_service_not_supported) }
	}
}

fn (mut s Server) tester_present(req &u8, req_len int, resp &u8) int {
	if req_len < 2 {
		return negative(resp, 0x3E, nrc_incorrect_length)
	}
	sub := unsafe { req[1] }
	if sub & 0x80 != 0 {
		return 0 // suppressPosRspMsgIndicationBit set -> stay silent
	}
	unsafe {
		resp[0] = 0x7E
		resp[1] = sub & 0x7F
	}
	return 2
}

fn (mut s Server) session_control(req &u8, req_len int, resp &u8) int {
	if req_len < 2 {
		return negative(resp, 0x10, nrc_incorrect_length)
	}
	s.session = unsafe { req[1] }
	unsafe {
		resp[0] = 0x50
		resp[1] = s.session
		resp[2] = 0x00 // P2_server_max  = 0x0032 (50 ms)
		resp[3] = 0x32
		resp[4] = 0x01 // P2*_server_max = 0x01F4 * 10 ms (5 s)
		resp[5] = 0xF4
	}
	return 6
}

fn (mut s Server) read_did(req &u8, req_len int, resp &u8) int {
	if req_len < 3 {
		return negative(resp, 0x22, nrc_incorrect_length)
	}
	did := unsafe { (u16(req[1]) << 8) | u16(req[2]) }
	for i in 0 .. s.ndid {
		if s.dids[i].id == did {
			unsafe {
				resp[0] = 0x62
				resp[1] = req[1]
				resp[2] = req[2]
				for j in 0 .. int(s.dids[i].len) {
					resp[3 + j] = s.dids[i].data[j]
				}
			}
			return 3 + int(s.dids[i].len)
		}
	}
	return negative(resp, 0x22, nrc_request_out_of_range)
}

fn (mut s Server) write_did(req &u8, req_len int, resp &u8) int {
	if req_len < 4 {
		return negative(resp, 0x2E, nrc_incorrect_length)
	}
	did := unsafe { (u16(req[1]) << 8) | u16(req[2]) }
	n := req_len - 3
	for i in 0 .. s.ndid {
		if s.dids[i].id == did {
			if !s.dids[i].writable {
				return negative(resp, 0x2E, nrc_conditions_not_correct)
			}
			if n > max_did_data {
				return negative(resp, 0x2E, nrc_request_out_of_range)
			}
			unsafe {
				for j in 0 .. n {
					s.dids[i].data[j] = req[3 + j]
				}
			}
			s.dids[i].len = u8(n)
			unsafe {
				resp[0] = 0x6E
				resp[1] = req[1]
				resp[2] = req[2]
			}
			return 3
		}
	}
	return negative(resp, 0x2E, nrc_request_out_of_range)
}

fn negative(resp &u8, sid u8, nrc u8) int {
	unsafe {
		resp[0] = 0x7F
		resp[1] = sid
		resp[2] = nrc
	}
	return 3
}
