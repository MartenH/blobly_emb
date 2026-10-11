module doip

import comm.isotp
import comm.uds

// DoIP (ISO 13400-2) server framing, no-alloc and transport-agnostic — the
// networked binding of the same uds.Server the bus transport uses (REQ-NET-007).
// The glue owns the sockets and hands this module raw TCP bytes; it assembles
// DoIP messages, drives the embedded uds.Server, and writes the response
// stream (ack + diagnostic response) back for the glue to send. One UDP frame,
// the vehicle announcement, is produced by `announcement` for the glue to
// broadcast at boot (discovery per ISO 13400).
//
// Scope: routing activation (0x0005/0x0006) under a configured policy (policy.v: which tester
// addresses, which activation types), alive check (0x0007/0x0008), entity status (0x4001/0x4002)
// and diagnostic power mode (0x4003/0x4004) on TCP and UDP alike, diagnostic message + acks
// (0x8001/0x8002/0x8003), generic NACK (0x0000), vehicle identification and announcement
// (0x0001..0x0004). One TCP_DATA socket (max_sockets): the socket-handler outcomes that need a
// second one — 0x01 all sockets in use, 0x03 source address active on another socket, and the
// alive check of the registered socket that decides them — have no state here to act on.
//
// The UDS server answering is either the embedded one or, when `serve.answer` is
// set, one the owner keeps elsewhere — a node with ONE diagnostic server reachable
// over both ISO-TP and DoIP (docs/diagnostics.md) hands DoIP a hook to it.
//
// A gateway (REQ-NET-019) also serves the logical addresses of nodes BEHIND it (`routes`): a
// diagnostic message to one is handed to `serve.route` (comm/diagroute on the thread that owns the
// buses), acknowledged from the routed node's address, and its answers come back later, one at a
// time, as routed_message frames them — the request is not answered within feed.

pub const header_len = 8

// the largest UDS message either way: one ISO-TP message, so a server shared with a CAN
// connection takes over DoIP whatever it takes there — a bootloader's TransferData block
// (boot.max_block_data) included — and answers whatever it answers there
pub const max_uds = isotp.max_payload

// the largest DoIP message this entity assembles: a diagnostic message carrying max_uds
// (header, source and target address, the UDS bytes)
pub const max_msg = header_len + 4 + max_uds

// the most tester addresses and activation types the routing-activation policy holds (policy.v);
// here, beside the arrays they size: declared in policy.v, the checker read them as 0 when
// indexing those arrays (V 0.5.x)
pub const max_testers = 8
pub const max_act_types = 4

// the response room one diagnostic message may need with a serve hook (its
// max_resp_per_msg): a feed buffer this size always makes progress
pub const max_resp = header_len + 5 + header_len + 4 + max_uds

// the functional logical address used when Server.functional_addr is 0 (ISO
// 13400-2's functional group range starts here)
pub const default_functional_addr = u16(0xE400)

// the most logical addresses a gateway routes to (Server.routes)
pub const max_routes = 8

// Serve is a UDS server DoIP does not own. `answer` handles one request and
// writes at most resp_cap bytes to resp, returning the response length (0 = no
// response). It runs on the caller of feed: a server another thread also drives
// is the owner's to serialise, and so is resetting it when the connection drops.
pub struct Serve {
pub mut:
	ctx    voidptr
	answer fn (ctx voidptr, req &u8, req_len int, functional bool, resp &u8, resp_cap int) int = unsafe { nil }
	// route forwards a request to the node behind the gateway at Server.routes[idx], for the
	// tester on connection `conn`, numbered `ticket` (its answers carry it back): 0 = forwarded,
	// else the diagnostic-message NACK code to answer with. nil = a node that routes nothing.
	route fn (ctx voidptr, idx int, req &u8, req_len int, conn u32, ticket u32) int = unsafe { nil }
}

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
const pt_alive_req = u16(0x0007)
const pt_alive_resp = u16(0x0008)
const pt_status_req = u16(0x4001)
const pt_status_resp = u16(0x4002)
const pt_power_req = u16(0x4003)
const pt_power_resp = u16(0x4004)
const pt_diag = u16(0x8001)
const pt_diag_ack = u16(0x8002)
const pt_diag_nack = u16(0x8003)

// generic NACK codes
const nack_bad_pattern = u8(0x00)
const nack_unknown_type = u8(0x01)
const nack_too_large = u8(0x02)
const nack_bad_length = u8(0x04)

// routing activation response codes (ISO 13400-2:2012). Every refusal below closes the socket.
const ra_unknown_source = u8(0x00) // the source address is not a tester this entity serves
const ra_source_differs = u8(0x02) // this socket is already registered to another source address
const ra_unsupported_type = u8(0x06) // an activation type this entity does not serve
const ra_ok = u8(0x10)

// entity status: node type "DoIP gateway" (it routes to nodes behind it) or "DoIP node"; power
// mode "ready"
const node_type_gateway = u8(0x00)
const node_type_node = u8(0x01)
const power_ready = u8(0x01)

// the largest DoIP message this entity accepts, as entity status reports it: the payload room of
// the assembly buffer — whether a tester reads the field as the payload or the whole message, a
// message sized to it fits
pub const max_data_size = max_msg - header_len

// diagnostic-message NACK codes
pub const dnack_invalid_source = u8(0x02)
pub const dnack_unknown_target = u8(0x03)
pub const dnack_out_of_memory = u8(0x05) // a gateway still sending the previous routed request
pub const dnack_unreachable = u8(0x06) // a routed target the tester may not reach (REQ-NET-020)
pub const dnack_transport_error = u8(0x08)

pub struct Server {
pub mut:
	entity_addr u16 // our DoIP logical address
	tester_addr u16 // learned from routing activation
	activated   bool
	// the transport must drop the connection once the response written so far is sent: the
	// stream desynced (bad pattern / oversized), a payload length was invalid for its type, or a
	// routing activation was refused with a code that closes the socket. feed processes nothing
	// after it.
	fatal bool
	// routing-activation policy (policy.v), set at boot. 0 entries = the defaults: any tester
	// address (tester_first..tester_last), activation type 0x00 only.
	testers     [max_testers]u16
	n_testers   int
	act_types   [max_act_types]u8
	n_act_types int
	vin         [17]u8
	uds         uds.Server // answers unless serve.answer is set
	serve       Serve
	// a diagnostic message to this address is a functional request (0 = default_functional_addr)
	functional_addr u16
	// assembly buffer: TCP chunks accumulate here until a message completes
	buf     [max_msg]u8
	buf_len int
	// a gateway's routes (REQ-NET-019): the logical addresses of the nodes behind it, set at boot
	routes   [max_routes]u16
	n_routes int
	// the tester connection: a number the transport moves on with every connection (end), so a
	// router's grant and answers belong to the connection they were made on
	conn u32
	// the latest routed request's number, and whether an answer to it is still to come (the
	// transport then polls for it at its fastest)
	ticket     u32
	route_open bool
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

// routed_message frames an answer of a node behind the gateway (`from`, its logical address) to
// the activated tester: a diagnostic message, `n` UDS bytes. Returns its length; out holds
// header_len + 4 + n bytes. An answer that is not responsePending is the request's last: no
// further one is expected (route_open).
pub fn (mut s Server) routed_message(from u16, uds_resp &u8, n int, out &u8) int {
	o := put_header(out, 0, pt_diag, u32(4 + n))
	unsafe {
		out[o] = u8(from >> 8)
		out[o + 1] = u8(from)
		out[o + 2] = u8(s.tester_addr >> 8)
		out[o + 3] = u8(s.tester_addr)
		for i in 0 .. n {
			out[o + 4 + i] = uds_resp[i]
		}
		if !(n >= 3 && uds_resp[0] == 0x7F && uds_resp[2] == 0x78) {
			s.route_open = false
		}
	}
	return o + 4 + n
}

// route_index: the route to logical address `ta`, or -1.
pub fn (s &Server) route_index(ta u16) int {
	for i in 0 .. s.n_routes {
		if s.routes[i] == ta {
			return i
		}
	}
	return -1
}

// response_message frames a further response to the activated tester — one its server sends after
// the answer to a request (a routine answered responsePending, then its next response): a
// diagnostic message from this entity, `n` UDS bytes. Returns its length; out holds header_len + 4
// + n bytes.
pub fn (s &Server) response_message(uds_resp &u8, n int, out &u8) int {
	o := put_header(out, 0, pt_diag, u32(4 + n))
	unsafe {
		out[o] = u8(s.entity_addr >> 8)
		out[o + 1] = u8(s.entity_addr)
		out[o + 2] = u8(s.tester_addr >> 8)
		out[o + 3] = u8(s.tester_addr)
		for i in 0 .. n {
			out[o + 4 + i] = uds_resp[i]
		}
	}
	return o + 4 + n
}

// announcement builds the vehicle-announcement payload (UDP broadcast at boot,
// also the answer to a vehicle-identification request): VIN, logical address,
// EID/GID (we use the MAC-derived EID for both), further-action 0x00.
pub fn (s &Server) announcement(eid &u8, resp &u8) int {
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

// udp_response answers one UDP datagram on port 13400: a vehicle-identification request
// (0x0001 any, 0x0002 by EID, 0x0003 by VIN) with the announcement — discovery must work after
// the boot broadcasts too — and entity status (0x4001) or diagnostic power mode (0x4003) with
// their responses (`open` is the TCP_DATA sockets open now). Returns 0 for anything that is not
// a well-formed, matching request (UDP: no NACKs, just silence). resp holds at least 64 bytes.
pub fn (s &Server) udp_response(data &u8, data_len int, eid &u8, open int, resp &u8) int {
	if data_len < header_len {
		return 0
	}
	unsafe {
		ptype := (u16(data[2]) << 8) | u16(data[3])
		// identification may use the generic version pattern 0xFF/0x00 — a
		// tester discovers entities without knowing their DoIP revision
		ident := ptype == pt_ident_any || ptype == pt_ident_eid || ptype == pt_ident_vin
		ver_ok := (data[0] == proto_ver && data[1] == proto_inv)
			|| (ident && data[0] == 0xFF && data[1] == 0x00)
		if !ver_ok {
			return 0
		}
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
			pt_status_req, pt_power_req {
				if plen != 0 {
					return 0
				}
				return s.info_response(ptype, open, resp, 0)
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
// resp_max must hold at least max_resp_per_msg(), or no message is ever served.
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
		if out + s.max_resp_per_msg() > resp_max {
			break
		}
		ptype := (u16(s.buf[2]) << 8) | u16(s.buf[3])
		out = s.dispatch(ptype, int(plen), resp, out)
		if s.fatal {
			// the connection closes after this response: what follows it is never served
			s.buf_len = 0
			break
		}
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
pub fn (s &Server) max_resp_per_msg() int {
	return diag_resp_at + s.uds_cap()
}

// where a UDS response starts in the frames answering one diagnostic message
const diag_resp_at = header_len + 5 + header_len + 4

// the longest UDS response the answering server may write
fn (s &Server) uds_cap() int {
	if s.serve.answer != unsafe { nil } {
		return max_uds
	}
	return if s.uds.resp_cap > 0 { s.uds.resp_cap } else { uds.legacy_resp_cap }
}

fn (mut s Server) dispatch(ptype u16, plen int, resp &u8, at int) int {
	match ptype {
		pt_route_req {
			// version-2 framing: exactly 7 bytes, or 11 with the optional OEM
			// field — a longer blob must NACK, not "activate" on its prefix
			if plen != 7 && plen != 11 {
				return s.bad_length(resp, at)
			}
			sa := (u16(s.buf[header_len]) << 8) | u16(s.buf[header_len + 1])
			code := s.activation_code(sa, s.buf[header_len + 2])
			if code == ra_ok {
				s.tester_addr = sa
				s.activated = true
			} else {
				s.fatal = true // every refusal this entity gives closes the socket
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
		pt_alive_resp {
			// the tester's answer to an alive check: carries its source address, needs no reply
			// (its arrival already counts as activity on the connection)
			if plen != 2 {
				return s.bad_length(resp, at)
			}
			return at
		}
		pt_alive_req, pt_status_req, pt_power_req {
			if plen != 0 {
				return s.bad_length(resp, at)
			}
			// on TCP the asker holds the one socket: it is open
			return s.info_response(ptype, 1, resp, at)
		}
		pt_diag {
			// addresses (4) + at least one UDS service byte: a data-less diag
			// message would get a positive ack and then no response — the
			// tester would wait forever
			if plen < 5 {
				return s.bad_length(resp, at)
			}
			sa := (u16(s.buf[header_len]) << 8) | u16(s.buf[header_len + 1])
			ta := (u16(s.buf[header_len + 2]) << 8) | u16(s.buf[header_len + 3])
			if !s.activated || sa != s.tester_addr {
				return s.diag_nack(resp, at, sa, dnack_invalid_source)
			}
			func_addr := if s.functional_addr != 0 {
				s.functional_addr
			} else {
				default_functional_addr
			}
			functional := ta == func_addr
			if ta != s.entity_addr && !functional {
				return s.route(ta, plen, resp, at, sa)
			}
			// the server writes its response straight to where it is framed,
			// within the room feed reserved; the ack and header go in front after
			cap := s.uds_cap()
			req := unsafe { &s.buf[header_len + 4] }
			out := unsafe { &resp[at + diag_resp_at] }
			ulen := if s.serve.answer != unsafe { nil } {
				s.serve.answer(s.serve.ctx, req, plen - 4, functional, out, cap)
			} else if functional {
				s.uds.handle_functional(req, plen - 4, out)
			} else {
				s.uds.handle(req, plen - 4, out)
			}
			if ulen < 0 || ulen > cap {
				return s.diag_nack(resp, at, sa, dnack_transport_error)
			}
			// positive ack first, from the address the request was sent to
			mut o := put_header(resp, at, pt_diag_ack, 5)
			unsafe {
				resp[o] = u8(ta >> 8)
				resp[o + 1] = u8(ta)
				resp[o + 2] = u8(sa >> 8)
				resp[o + 3] = u8(sa)
				resp[o + 4] = 0x00 // ack
			}
			o += 5
			if ulen > 0 {
				// then the UDS response as its own message, from this entity
				o = put_header(resp, o, pt_diag, u32(4 + ulen))
				unsafe {
					resp[o] = u8(s.entity_addr >> 8)
					resp[o + 1] = u8(s.entity_addr)
					resp[o + 2] = u8(sa >> 8)
					resp[o + 3] = u8(sa)
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

// route hands a diagnostic message for a node behind the gateway to the router: acknowledged from
// that node's address when forwarded (its answers follow, routed_message), NACKed from it when not.
// A target that is not routed is unknown, as on a plain node.
fn (mut s Server) route(ta u16, plen int, resp &u8, at int, sa u16) int {
	idx := s.route_index(ta)
	if idx < 0 || s.serve.route == unsafe { nil } {
		return s.diag_nack(resp, at, sa, dnack_unknown_target)
	}
	// the request's ticket — the latest only once forwarded: a refused one leaves the request in
	// flight its own, so its answers still go out
	ticket := s.ticket + 1
	code := s.serve.route(s.serve.ctx, idx, unsafe { &s.buf[header_len + 4] }, plen - 4, s.conn,
		ticket)
	if code != 0 {
		return s.diag_nack_from(resp, at, ta, sa, u8(code))
	}
	s.ticket = ticket
	s.route_open = true
	o := put_header(resp, at, pt_diag_ack, 5)
	unsafe {
		resp[o] = u8(ta >> 8)
		resp[o + 1] = u8(ta)
		resp[o + 2] = u8(sa >> 8)
		resp[o + 3] = u8(sa)
		resp[o + 4] = 0x00 // ack
	}
	return o + 5
}

// activation_code: the routing activation handler's answer for one request on this socket, in
// the order ISO 13400-2 checks it — the source address, the activation type, then the socket
// (already registered to another source address). Re-activation by the registered address
// succeeds again.
fn (s &Server) activation_code(sa u16, atype u8) u8 {
	if !s.tester_allowed(sa) {
		return ra_unknown_source
	}
	if !s.type_served(atype) {
		return ra_unsupported_type
	}
	if s.activated && sa != s.tester_addr {
		return ra_source_differs
	}
	return ra_ok
}

fn (s &Server) tester_allowed(sa u16) bool {
	if s.n_testers == 0 {
		return tester_address_ok(sa)
	}
	for i in 0 .. s.n_testers {
		if s.testers[i] == sa {
			return true
		}
	}
	return false
}

fn (s &Server) type_served(atype u8) bool {
	if s.n_act_types == 0 {
		return atype == 0x00
	}
	for i in 0 .. s.n_act_types {
		if s.act_types[i] == atype {
			return true
		}
	}
	return false
}

// info_response answers the three requests that carry no data — alive check, entity status and
// diagnostic power mode — on either transport. `open` is the TCP_DATA sockets open now.
fn (s &Server) info_response(ptype u16, open int, resp &u8, at int) int {
	match ptype {
		pt_alive_req {
			// ISO 13400-2 sends this request from the entity to the tester; a tester asking it of
			// the entity (a liveness probe, as common clients offer) gets the same answer a tester
			// gives: this entity's address
			o := put_header(resp, at, pt_alive_resp, 2)
			unsafe {
				resp[o] = u8(s.entity_addr >> 8)
				resp[o + 1] = u8(s.entity_addr)
			}
			return o + 2
		}
		pt_status_req {
			// node type, max concurrent TCP_DATA sockets, currently open ones, max data size
			o := put_header(resp, at, pt_status_resp, 7)
			unsafe {
				resp[o] = if s.n_routes > 0 { node_type_gateway } else { node_type_node }
				resp[o + 1] = u8(max_sockets)
				resp[o + 2] = u8(open)
				resp[o + 3] = u8(u32(max_data_size) >> 24)
				resp[o + 4] = u8(u32(max_data_size) >> 16)
				resp[o + 5] = u8(u32(max_data_size) >> 8)
				resp[o + 6] = u8(max_data_size)
			}
			return o + 7
		}
		else {
			// diagnostic power mode: a running node is ready for diagnostics
			o := put_header(resp, at, pt_power_resp, 1)
			unsafe {
				resp[o] = power_ready
			}
			return o + 1
		}
	}
}

// bad_length: generic NACK 0x04 (invalid payload length) — and, as ISO 13400-2's header handler
// requires for that code, the socket closes after it
fn (mut s Server) bad_length(resp &u8, at int) int {
	s.fatal = true
	return gen_nack(resp, at, nack_bad_length)
}

fn (mut s Server) diag_nack(resp &u8, at int, sa u16, code u8) int {
	return s.diag_nack_from(resp, at, s.entity_addr, sa, code)
}

// diag_nack_from: a diagnostic-message NACK from `from` — this entity, or the routed node the
// message was for
fn (mut s Server) diag_nack_from(resp &u8, at int, from u16, sa u16, code u8) int {
	o := put_header(resp, at, pt_diag_nack, 5)
	unsafe {
		resp[o] = u8(from >> 8)
		resp[o + 1] = u8(from)
		resp[o + 2] = u8(sa >> 8)
		resp[o + 3] = u8(sa)
		resp[o + 4] = code
	}
	return o + 5
}
