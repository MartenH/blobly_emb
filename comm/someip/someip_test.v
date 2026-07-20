module someip

// Host-run SOME/IP envelope tests (sim-first): the same bytes the H735 will
// send/see over UDP, without hardware. Golden vectors are hand-computed
// big-endian. Groundwork for REQ-NET-014/015, deliberately left untagged for
// trace: 014 also covers remote calls (the RPC phase) and 015 the counted-drop
// routing path; those requirements verify at their rungs, not from the codec
// alone.

// the doc's sketch: service 0x0100, event 0x8001, iface version 1, 4-byte payload
fn golden() Header {
	return notification(0x0100, 0x8001, 1, 4)
}

const golden_bytes = [u8(0x01), 0x00, 0x80, 0x01, 0x00, 0x00, 0x00, 0x0C, 0x00, 0x00, 0x00, 0x00,
	0x01, 0x01, 0x02, 0x00]

fn test_encode_matches_golden_vector() {
	mut buf := [header_len]u8{}
	n := encode(golden(), &buf[0])
	assert n == header_len
	for i in 0 .. header_len {
		assert buf[i] == golden_bytes[i], 'byte ${i}'
	}
}

fn test_decode_roundtrips_golden_vector() {
	h, ok := decode(&golden_bytes[0], golden_bytes.len)
	assert ok
	assert h == golden()
}

fn test_decode_rejects_short_datagram() {
	_, ok := decode(&golden_bytes[0], header_len - 1)
	assert !ok
}

fn test_event_accepts_the_golden_envelope() {
	assert check_event(golden(), header_len + 4, 0x0100, 1) == Drop.none
}

fn test_event_drops_by_reason() {
	dlen := header_len + 4
	mut h := golden()
	h.proto = 0x02
	assert check_event(h, dlen, 0x0100, 1) == Drop.proto

	h = golden()
	assert check_event(h, dlen, 0x0200, 1) == Drop.service // foreign service
	assert check_event(h, dlen, 0x0100, 2) == Drop.iface // stale build

	h.mtype = mt_request
	assert check_event(h, dlen, 0x0100, 1) == Drop.mtype

	h = golden()
	h.method = 0x0001 // a method id where an event must be
	assert check_event(h, dlen, 0x0100, 1) == Drop.method
}

fn test_event_drops_nonzero_fixed_fields() {
	dlen := header_len + 4
	mut h := golden()
	h.session = 1 // a session counter is nonconforming on notifications
	assert check_event(h, dlen, 0x0100, 1) == Drop.fixed
	h = golden()
	h.client = 0x0E00
	assert check_event(h, dlen, 0x0100, 1) == Drop.fixed
	h = golden()
	h.rcode = rc_not_ok
	assert check_event(h, dlen, 0x0100, 1) == Drop.fixed
}

fn test_event_drops_inconsistent_length() {
	// header claims 4 payload bytes, datagram carries 8: a self-inconsistent
	// envelope must never reach a fixed-layout decoder
	assert check_event(golden(), header_len + 8, 0x0100, 1) == Drop.length
}

fn test_event_drops_oversize_payload() {
	h := notification(0x0100, 0x8001, 1, max_payload + 1)
	dlen := header_len + max_payload + 1
	assert check_event(h, dlen, 0x0100, 1) == Drop.oversize
}

// --- P3 RPC transport: builders + the server-side request gate ------------
// Groundwork for REQ-NET-016, deliberately left untagged for trace: 016
// verifies when a configured method is invocable end to end (the routing
// rung), not from the transport layer alone.

// the doc's sketch: method 0x0001 on the same service, client 0x0E01,
// session 7, 2-byte payload
fn golden_req() Header {
	return request(0x0100, 0x0001, 0x0E01, 7, 1, 2)
}

const golden_req_bytes = [u8(0x01), 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x0A, 0x0E, 0x01, 0x00,
	0x07, 0x01, 0x01, 0x00, 0x00]

fn test_request_matches_golden_vector() {
	mut buf := [header_len]u8{}
	n := encode(golden_req(), &buf[0])
	assert n == header_len
	for i in 0 .. header_len {
		assert buf[i] == golden_req_bytes[i], 'byte ${i}'
	}
}

fn test_response_mirrors_the_request_id() {
	// the correlation law (REQ-NET-016's core): service/method/client/session
	// mirrored verbatim; only type, length and rc may differ
	r := response(golden_req(), 4)
	assert r.service == golden_req().service
	assert r.method == golden_req().method
	assert r.client == golden_req().client
	assert r.session == golden_req().session
	assert r.iface == golden_req().iface
	assert r.mtype == mt_response
	assert r.rcode == rc_ok
	assert r.length == u32(8 + 4)
}

fn test_error_response_is_distinguishable() {
	e := error_response(golden_req(), rc_unknown_method)
	assert e.mtype == mt_error
	assert e.rcode == rc_unknown_method
	assert e.length == u32(8) // no payload: failures carry no schema
	// still attributable to the originating request
	assert e.client == golden_req().client
	assert e.session == golden_req().session
}

fn test_request_gate_accepts_the_golden_envelope() {
	assert check_request(golden_req(), header_len + 2, 0x0100, 1) == Drop.none
}

fn test_request_gate_drops_by_reason() {
	dlen := header_len + 2
	mut h := golden_req()
	h.proto = 0x02
	assert check_request(h, dlen, 0x0100, 1) == Drop.proto

	h = golden_req()
	assert check_request(h, dlen, 0x0200, 1) == Drop.service // foreign service
	assert check_request(h, dlen, 0x0100, 2) == Drop.iface // stale build

	h.mtype = mt_notification
	assert check_request(h, dlen, 0x0100, 1) == Drop.mtype

	h = golden_req()
	h.method = 0x8001 // an event id where a method must be
	assert check_request(h, dlen, 0x0100, 1) == Drop.method

	h = golden_req()
	h.session = 0 // a dead session id could not correlate the response
	assert check_request(h, dlen, 0x0100, 1) == Drop.fixed
	h = golden_req()
	h.rcode = rc_not_ok
	assert check_request(h, dlen, 0x0100, 1) == Drop.fixed

	assert check_request(golden_req(), header_len + 6, 0x0100, 1) == Drop.length

	ho := request(0x0100, 0x0001, 0x0E01, 7, 1, max_payload + 1)
	assert check_request(ho, header_len + max_payload + 1, 0x0100, 1) == Drop.oversize
}
