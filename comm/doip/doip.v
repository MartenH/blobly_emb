module doip

import comm.uds

// DoIP (ISO 13400-2) server framing, no-alloc and transport-agnostic — the
// networked binding of the same uds.Server the bus transport uses (REQ-NET-007).
// The glue owns the sockets and hands this module raw TCP bytes; it assembles
// DoIP messages, drives the embedded uds.Server, and writes the response
// stream (ack + diagnostic response) back for the glue to send. One UDP frame,
// the vehicle announcement, is produced by `announcement` for the glue to
// broadcast at boot (discovery per ISO 13400).
//
// Scope (P3b first cut): routing activation (0x0005/0x0006), diagnostic
// message + acks (0x8001/0x8002/0x8003), generic NACK (0x0000), vehicle
// announcement (0x0004). Alive-check and entity-status answer as unknown-type
// NACKs until a phase needs them.

pub const header_len = 8
pub const max_msg = 256 // DoIP header + the largest UDS payload we serve

const proto_ver = u8(0x02) // ISO 13400-2:2012
const proto_inv = u8(0xFD)

// payload types
const pt_gen_nack = u16(0x0000)
const pt_ident_any = u16(0x0001) // vehicle identification request
const pt_ident_eid = u16(0x0002) // ... by EID
const pt_ident_vin = u16(0x0003) // ... by VIN
const pt_announce = u16(0x0004)
const pt_route_req = u16(0x0005)
const pt_route_resp = u16(0x0006)
const pt_diag = u16(0x8001)
const pt_diag_ack = u16(0x8002)
const pt_diag_nack = u16(0x8003)

// generic NACK codes
const nack_bad_pattern = u8(0x00)
const nack_unknown_type = u8(0x01)
const nack_too_large = u8(0x02)
const nack_bad_length = u8(0x04)

// diagnostic-message NACK codes
const dnack_invalid_source = u8(0x02)
const dnack_unknown_target = u8(0x03)

pub struct Server {
pub mut:
	entity_addr u16 // our DoIP logical address
	tester_addr u16 // learned from routing activation
	activated   bool
	fatal       bool // stream desynced (bad pattern / oversized): transport must drop the connection
	vin         [17]u8
	uds         uds.Server
	// assembly buffer: TCP chunks accumulate here until a message completes
	buf     [max_msg]u8
	buf_len int
}

fn put_header(resp &u8, at int, ptype u16, plen u32) int {
	unsafe {
		resp[at] = proto_ver
		resp[at + 1] = proto_inv
		resp[at + 2] = u8(ptype >> 8)
		resp[at + 3] = u8(ptype)
		resp[at + 4] = u8(plen >> 24)
		resp[at + 5] = u8(plen >> 16)
		resp[at + 6] = u8(plen >> 8)
		resp[at + 7] = u8(plen)
	}
	return at + header_len
}

fn gen_nack(resp &u8, at int, code u8) int {
	o := put_header(resp, at, pt_gen_nack, 1)
	unsafe {
		resp[o] = code
	}
	return o + 1
}

// gen_nack gated on the caller's response capacity: feed's early NACKs run
// before the per-message room check, and with bounds checks off an unguarded
// write past resp_max is an out-of-bounds write, not a crash
fn nack_if_room(resp &u8, at int, code u8, resp_max int) int {
	if at + header_len + 1 > resp_max {
		return at
	}
	return gen_nack(resp, at, code)
}

// announcement builds the vehicle-announcement payload (UDP broadcast at boot,
// also the answer to a vehicle-identification request): VIN, logical address,
// EID/GID (we use the MAC-derived EID for both), further-action 0x00.
pub fn (mut s Server) announcement(eid &u8, resp &u8) int {
	o := put_header(resp, 0, pt_announce, 17 + 2 + 6 + 6 + 1)
	unsafe {
		for i in 0 .. 17 {
			resp[o + i] = s.vin[i]
		}
		resp[o + 17] = u8(s.entity_addr >> 8)
		resp[o + 18] = u8(s.entity_addr)
		for i in 0 .. 6 {
			resp[o + 19 + i] = eid[i]
			resp[o + 25 + i] = eid[i]
		}
		resp[o + 31] = 0 // further action: none
	}
	return o + 32
}

// ident_response answers a UDP vehicle-identification request (0x0001 any,
// 0x0002 by EID, 0x0003 by VIN) with the announcement — discovery must work
// after the boot broadcasts too. Returns 0 for anything that is not a
// well-formed, matching request (UDP: no NACKs, just silence).
pub fn (mut s Server) ident_response(data &u8, data_len int, eid &u8, resp &u8) int {
	if data_len < header_len {
		return 0
	}
	unsafe {
		// identification may use the generic version pattern 0xFF/0x00 — a
		// tester discovers entities without knowing their DoIP revision
		ver_ok := (data[0] == proto_ver && data[1] == proto_inv)
			|| (data[0] == 0xFF && data[1] == 0x00)
		if !ver_ok {
			return 0
		}
		ptype := (u16(data[2]) << 8) | u16(data[3])
		plen := (u32(data[4]) << 24) | (u32(data[5]) << 16) | (u32(data[6]) << 8) | u32(data[7])
		if u32(data_len - header_len) != plen {
			return 0
		}
		match ptype {
			pt_ident_any {
				if plen != 0 {
					return 0
				}
			}
			pt_ident_eid {
				if plen != 6 {
					return 0
				}
				for i in 0 .. 6 {
					if data[header_len + i] != eid[i] {
						return 0
					}
				}
			}
			pt_ident_vin {
				if plen != 17 {
					return 0
				}
				for i in 0 .. 17 {
					if data[header_len + i] != s.vin[i] {
						return 0
					}
				}
			}
			else {
				return 0
			}
		}
	}
	return s.announcement(eid, resp)
}

// feed consumes one chunk of TCP bytes and processes every COMPLETE DoIP message
// assembled so far; the response stream (possibly several frames: ack + reply)
// is written to resp. Returns the number of response bytes (0 = nothing yet).
pub fn (mut s Server) feed(data &u8, data_len int, resp &u8, resp_max int) int {
	// append (a chunk that would overflow the assembly buffer is a too-large
	// message: drop the stream state and NACK — the glue closes on that).
	if s.buf_len + data_len > max_msg {
		s.buf_len = 0
		s.fatal = true
		return nack_if_room(resp, 0, nack_too_large, resp_max)
	}
	unsafe {
		for i in 0 .. data_len {
			s.buf[s.buf_len + i] = data[i]
		}
	}
	s.buf_len += data_len

	mut out := 0
	for {
		if s.buf_len < header_len {
			break
		}
		if s.buf[0] != proto_ver || s.buf[1] != proto_inv {
			s.buf_len = 0
			s.fatal = true
			return nack_if_room(resp, out, nack_bad_pattern, resp_max)
		}
		plen := (u32(s.buf[4]) << 24) | (u32(s.buf[5]) << 16) | (u32(s.buf[6]) << 8) | u32(s.buf[7])
		// compare in u32: a high-bit length narrowed to int goes negative and
		// would bypass the bound, then run the shift loop off the buffer
		if plen > u32(max_msg - header_len) {
			s.buf_len = 0
			s.fatal = true
			return nack_if_room(resp, out, nack_too_large, resp_max)
		}
		total := header_len + int(plen)
		if s.buf_len < total {
			break // wait for more bytes
		}
		// stop (don't consume) when the worst-case response for one more message
		// no longer fits: the message stays buffered and the caller drains it
		// with feed(len 0) after sending what accumulated so far
		if out + max_resp_per_msg > resp_max {
			break
		}
		ptype := (u16(s.buf[2]) << 8) | u16(s.buf[3])
		out = s.dispatch(ptype, int(plen), resp, out)
		// shift any following message to the front
		unsafe {
			for i in 0 .. s.buf_len - total {
				s.buf[i] = s.buf[total + i]
			}
		}
		s.buf_len -= total
	}
	return out
}

// worst response per message: ack(8+5) + diag hdr(8+4) + uds resp — feed
// stops before dispatching a message this might not fit
const max_resp_per_msg = header_len + 5 + header_len + 4 + int(uds.max_did_data) + 3

fn (mut s Server) dispatch(ptype u16, plen int, resp &u8, at int) int {
	match ptype {
		pt_route_req {
			// version-2 framing: exactly 7 bytes, or 11 with the optional OEM
			// field — a longer blob must NACK, not "activate" on its prefix
			if plen != 7 && plen != 11 {
				return gen_nack(resp, at, nack_bad_length)
			}
			sa := (u16(s.buf[header_len]) << 8) | u16(s.buf[header_len + 1])
			// only the default activation type (0x00) is served; anything else
			// (WWH-OBD, OEM ranges) must be rejected, not silently "activated"
			// under semantics we do not implement
			mut code := u8(0x10) // routing successfully activated
			if s.buf[header_len + 2] == 0x00 {
				s.tester_addr = sa
				s.activated = true
			} else {
				code = 0x06 // unsupported routing activation type
			}
			o := put_header(resp, at, pt_route_resp, 9)
			unsafe {
				resp[o] = u8(sa >> 8)
				resp[o + 1] = u8(sa)
				resp[o + 2] = u8(s.entity_addr >> 8)
				resp[o + 3] = u8(s.entity_addr)
				resp[o + 4] = code
				resp[o + 5] = 0
				resp[o + 6] = 0
				resp[o + 7] = 0
				resp[o + 8] = 0
			}
			return o + 9
		}
		pt_diag {
			// addresses (4) + at least one UDS service byte: a data-less diag
			// message would get a positive ack and then no response — the
			// tester would wait forever
			if plen < 5 {
				return gen_nack(resp, at, nack_bad_length)
			}
			sa := (u16(s.buf[header_len]) << 8) | u16(s.buf[header_len + 1])
			ta := (u16(s.buf[header_len + 2]) << 8) | u16(s.buf[header_len + 3])
			if !s.activated || sa != s.tester_addr {
				return s.diag_nack(resp, at, sa, dnack_invalid_source)
			}
			if ta != s.entity_addr {
				return s.diag_nack(resp, at, sa, dnack_unknown_target)
			}
			// positive ack first, then the UDS response as its own message
			mut o := put_header(resp, at, pt_diag_ack, 5)
			unsafe {
				resp[o] = u8(s.entity_addr >> 8)
				resp[o + 1] = u8(s.entity_addr)
				resp[o + 2] = u8(sa >> 8)
				resp[o + 3] = u8(sa)
				resp[o + 4] = 0x00 // ack
			}
			o += 5
			mut ubuf := [uds.max_did_data + 8]u8{}
			ulen := s.uds.handle(unsafe { &s.buf[header_len + 4] }, plen - 4, &ubuf[0])
			if ulen > 0 {
				o = put_header(resp, o, pt_diag, u32(4 + ulen))
				unsafe {
					resp[o] = u8(s.entity_addr >> 8)
					resp[o + 1] = u8(s.entity_addr)
					resp[o + 2] = u8(sa >> 8)
					resp[o + 3] = u8(sa)
					for i in 0 .. ulen {
						resp[o + 4 + i] = ubuf[i]
					}
				}
				o += 4 + ulen
			}
			return o
		}
		else {
			return gen_nack(resp, at, nack_unknown_type)
		}
	}
}

fn (mut s Server) diag_nack(resp &u8, at int, sa u16, code u8) int {
	o := put_header(resp, at, pt_diag_nack, 5)
	unsafe {
		resp[o] = u8(s.entity_addr >> 8)
		resp[o + 1] = u8(s.entity_addr)
		resp[o + 2] = u8(sa >> 8)
		resp[o + 3] = u8(sa)
		resp[o + 4] = code
	}
	return o + 5
}
