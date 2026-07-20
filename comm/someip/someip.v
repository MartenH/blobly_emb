module someip

import comm.com

// SOME/IP wire codec + rx envelope gate (docs/someip.md) — the standard 16-byte
// header, big-endian on the wire; the payload (the config-derived layout, or a
// module's own bytes) is opaque here. Pure bytes-in/bytes-out platform V, no
// sockets, no alloc: the glue owns UDP (the netx_glue byte-pipe seam, as DoIP)
// and checks the source endpoint; the router owns payload-vs-route length.
//
// Scope: encode/decode + notification tx + the event rx gate (P1/P2), and
// the RPC transport (P3, this layer): request/response/error builders with
// the correlation law — a response mirrors its request's Request ID — plus
// the server-side request gate. The client adapter state (one in-flight per
// method, deadline, drain) arrives with the method-routing rung; SD does not
// exist on target (static endpoints, REQ-NET-017).

pub const header_len = 16
pub const max_payload = com.max_pdu // one event = one PDU: the shared 64-byte bound

pub const proto_ver = u8(0x01)
pub const event_bit = u16(0x8000) // bit 15 of the method/event id: set = event

// message types (the subset the design admits)
pub const mt_request = u8(0x00)
pub const mt_notification = u8(0x02)
pub const mt_response = u8(0x80)
pub const mt_error = u8(0x81)

// return codes (the standard set the phases use)
pub const rc_ok = u8(0x00)
pub const rc_not_ok = u8(0x01)
pub const rc_unknown_service = u8(0x02)
pub const rc_unknown_method = u8(0x03)
pub const rc_not_ready = u8(0x04)
pub const rc_timeout = u8(0x06)
pub const rc_wrong_proto = u8(0x07)
pub const rc_wrong_iface = u8(0x08)
pub const rc_malformed = u8(0x09)
pub const rc_wrong_type = u8(0x0A)

pub struct Header {
pub mut:
	service u16
	method  u16 // method/event id; bit 15 set = event/notification
	length  u32 // 8 + payload bytes (everything after the Length field)
	client  u16 // Request ID high half; 0 on notifications
	session u16 // Request ID low half; 0 on notifications
	proto   u8
	iface   u8
	mtype   u8
	rcode   u8
}

// encode writes the 16-byte header into dst (big-endian) and returns header_len.
pub fn encode(h Header, dst &u8) int {
	unsafe {
		dst[0] = u8(h.service >> 8)
		dst[1] = u8(h.service)
		dst[2] = u8(h.method >> 8)
		dst[3] = u8(h.method)
		dst[4] = u8(h.length >> 24)
		dst[5] = u8(h.length >> 16)
		dst[6] = u8(h.length >> 8)
		dst[7] = u8(h.length)
		dst[8] = u8(h.client >> 8)
		dst[9] = u8(h.client)
		dst[10] = u8(h.session >> 8)
		dst[11] = u8(h.session)
		dst[12] = h.proto
		dst[13] = h.iface
		dst[14] = h.mtype
		dst[15] = h.rcode
	}
	return header_len
}

// decode parses a datagram's header. ok = false when the datagram cannot hold one.
pub fn decode(data &u8, data_len int) (Header, bool) {
	if data_len < header_len {
		return Header{}, false
	}
	mut h := Header{}
	unsafe {
		h.service = (u16(data[0]) << 8) | u16(data[1])
		h.method = (u16(data[2]) << 8) | u16(data[3])
		h.length = (u32(data[4]) << 24) | (u32(data[5]) << 16) | (u32(data[6]) << 8) | u32(data[7])
		h.client = (u16(data[8]) << 8) | u16(data[9])
		h.session = (u16(data[10]) << 8) | u16(data[11])
		h.proto = data[12]
		h.iface = data[13]
		h.mtype = data[14]
		h.rcode = data[15]
	}
	return h, true
}

// notification builds the tx header for an event publication: Request ID zero
// (strict stacks reject nonzero — the interop point of REQ-NET-014), rc ok.
pub fn notification(service u16, event u16, iface u8, payload_len int) Header {
	return Header{
		service: service
		method:  event
		length:  u32(8 + payload_len)
		proto:   proto_ver
		iface:   iface
		mtype:   mt_notification
		rcode:   rc_ok
	}
}

// Drop is why an inbound datagram was refused — the platform counts by reason
// (REQ-NET-015: counted and dropped, never faulting). .none = accept.
pub enum Drop {
	none
	short   // datagram cannot hold a header
	proto   // wrong protocol version
	service // foreign service id
	iface   // interface version mismatch
	mtype   // message type not legal for the phase
	method  // the id's bit-15 class does not match its role (event set, method clear)
	fixed   // a fixed field violated: notification Request ID / Return Code
	// not zero, or a request without a live session id / with rc set
	length   // Length inconsistent with the datagram
	oversize // payload exceeds the shared PDU bound
}

// --- P3 RPC transport (docs/someip.md): builders + the server-side gate ---

// request builds a client request header for `method` (bit 15 clear). The
// Request ID is the correlation token: client + session, mirrored verbatim by
// the response (REQ-NET-016). session must be live (nonzero, wrapping 1..):
// the server gate refuses a dead session id.
pub fn request(service u16, method u16, client u16, session u16, iface u8, payload_len int) Header {
	return Header{
		service: service
		method:  method
		length:  u32(8 + payload_len)
		client:  client
		session: session
		proto:   proto_ver
		iface:   iface
		mtype:   mt_request
		rcode:   rc_ok
	}
}

// response builds the success response to `req`: the correlation law — the
// request's service/method/Request ID mirrored verbatim — with only the
// message type (0x80) and payload differing.
pub fn response(req Header, payload_len int) Header {
	mut h := req
	h.length = u32(8 + payload_len)
	h.mtype = mt_response
	h.rcode = rc_ok
	return h
}

// error_response builds the distinguishable failure answer to `req`: message
// type 0x81, the given nonzero return code, no payload — the outcome stays
// attributable to the originating request (same mirrored Request ID) without
// inventing a payload schema for failures.
pub fn error_response(req Header, rc u8) Header {
	mut h := req
	h.length = u32(8)
	h.mtype = mt_error
	h.rcode = rc
	return h
}

// check_request validates an inbound REQUEST envelope against the configured
// identity — the server-side twin of check_event. Same counter discipline
// (identity before shape); method ids have bit 15 CLEAR, and the Request ID
// must carry a live session (nonzero) or the response could not be
// correlated. Whether the method id is actually served is the router's check
// (unknown method -> rc_unknown_method error response, not a silent drop).
pub fn check_request(h Header, datagram_len int, service u16, iface u8) Drop {
	if datagram_len < header_len {
		return .short
	}
	if h.proto != proto_ver {
		return .proto
	}
	if h.service != service {
		return .service
	}
	if h.iface != iface {
		return .iface
	}
	if h.mtype != mt_request {
		return .mtype
	}
	if (h.method & event_bit) != 0 {
		return .method
	}
	if h.session == 0 || h.rcode != rc_ok {
		return .fixed
	}
	if h.length != u32(datagram_len - 8) {
		return .length
	}
	if datagram_len - header_len > max_payload {
		return .oversize
	}
	return .none
}

// check_event validates an inbound NOTIFICATION envelope against the configured
// identity (docs/someip.md "On rx") — everything except the UDP source (the
// glue's check) and payload-vs-route length (the router's, which knows the
// frame). Order matters for the counters: identity before shape.
pub fn check_event(h Header, datagram_len int, service u16, iface u8) Drop {
	if datagram_len < header_len {
		return .short
	}
	if h.proto != proto_ver {
		return .proto
	}
	if h.service != service {
		return .service
	}
	if h.iface != iface {
		return .iface
	}
	if h.mtype != mt_notification {
		return .mtype
	}
	if (h.method & event_bit) == 0 {
		return .method
	}
	if h.client != 0 || h.session != 0 || h.rcode != rc_ok {
		return .fixed
	}
	if h.length != u32(datagram_len - 8) {
		return .length
	}
	if datagram_len - header_len > max_payload {
		return .oversize
	}
	return .none
}
