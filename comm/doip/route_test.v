module doip

// A gateway's routed diagnostic messages (REQ-NET-019): acknowledged or refused from the routed
// node's address, handed to the router with the connection and a ticket, the answers framed later
// from that address — and the entity reports itself a gateway.
// @verifies REQ-NET-019

// a DoIP message into dst (each test file is compiled on its own: doip_test.v's helper is not here)
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

struct RouteCall {
mut:
	calls  int
	idx    int
	req    []u8
	conn   u32
	ticket u32
	code   int
}

fn route_hook(ctx voidptr, idx int, req &u8, req_len int, conn u32, ticket u32) int {
	mut c := unsafe { &RouteCall(ctx) }
	c.calls++
	c.idx = idx
	c.req = unsafe { req.vbytes(req_len) }.clone()
	c.conn = conn
	c.ticket = ticket
	return c.code
}

const gw = u16(0x07A0)
const zone = u16(0x07C0)
const tester = u16(0x0E00)

fn gateway(mut call RouteCall) Server {
	mut s := Server{}
	s.entity_addr = gw
	s.uds.session = 0x01
	s.routes[0] = 0x07B0
	s.routes[1] = zone
	s.n_routes = 2
	s.serve.ctx = call
	s.serve.route = route_hook
	mut inb := [max_msg]u8{}
	mut resp := [max_resp]u8{}
	n := frame(&inb[0], 0x0005, [u8(tester >> 8), u8(tester), 0x00, 0, 0, 0, 0])
	s.feed(&inb[0], n, &resp[0], max_resp)
	assert s.activated
	return s
}

fn diag_to(mut s Server, ta u16, uds []u8) []u8 {
	mut payload := [u8(tester >> 8), u8(tester), u8(ta >> 8), u8(ta)]
	payload << uds
	mut inb := [max_msg]u8{}
	mut resp := [max_resp]u8{}
	n := frame(&inb[0], 0x8001, payload)
	rlen := s.feed(&inb[0], n, &resp[0], max_resp)
	return resp[..rlen].clone()
}

fn test_a_routed_request_is_acknowledged_from_the_node_and_answered_later() {
	mut call := RouteCall{}
	mut s := gateway(mut call)
	s.conn = 3
	out := diag_to(mut s, zone, [u8(0x22), 0xF1, 0x90])
	assert out.len == 8 + 5 // the positive ack alone: the answer is not the gateway's to give now
	assert out[2] == 0x80 && out[3] == 0x02
	assert (u16(out[8]) << 8 | out[9]) == zone // from the routed node
	assert (u16(out[10]) << 8 | out[11]) == tester
	assert out[12] == 0x00
	assert call.calls == 1
	assert call.idx == 1
	assert call.req == [u8(0x22), 0xF1, 0x90]
	assert call.conn == 3
	assert call.ticket == 1
	assert s.route_open
	// the next routed request gets the next ticket
	diag_to(mut s, zone, [u8(0x3E), 0x00])
	assert call.ticket == 2
}

fn test_a_refused_routed_request_is_nacked_from_the_node_with_the_routers_code() {
	mut call := RouteCall{
		code: int(dnack_unreachable)
	}
	mut s := gateway(mut call)
	out := diag_to(mut s, zone, [u8(0x10), 0x03])
	assert out.len == 8 + 5
	assert out[2] == 0x80 && out[3] == 0x03
	assert (u16(out[8]) << 8 | out[9]) == zone
	assert out[12] == dnack_unreachable
	assert !s.route_open
	assert !s.fatal // a refused message leaves the connection as it is
}

fn test_an_address_the_gateway_does_not_route_is_unknown_from_the_entity() {
	mut call := RouteCall{}
	mut s := gateway(mut call)
	out := diag_to(mut s, 0x1234, [u8(0x3E), 0x00])
	assert out[2] == 0x80 && out[3] == 0x03
	assert (u16(out[8]) << 8 | out[9]) == gw
	assert out[12] == dnack_unknown_target
	assert call.calls == 0
}

fn test_a_node_without_a_router_routes_nothing() {
	mut call := RouteCall{}
	mut s := gateway(mut call)
	s.serve.route = unsafe { nil }
	out := diag_to(mut s, zone, [u8(0x3E), 0x00])
	assert out[12] == dnack_unknown_target
}

fn test_a_routed_request_before_activation_is_an_invalid_source() {
	mut call := RouteCall{}
	mut s := gateway(mut call)
	s.activated = false
	out := diag_to(mut s, zone, [u8(0x3E), 0x00])
	assert out[12] == dnack_invalid_source
	assert call.calls == 0
}

fn test_the_gateways_own_address_and_the_functional_one_stay_local() {
	mut call := RouteCall{}
	mut s := gateway(mut call)
	s.uds.dids[0].id = 0xF190
	s.uds.dids[0].data[0] = `G`
	s.uds.dids[0].len = 1
	s.uds.ndid = 1
	out := diag_to(mut s, gw, [u8(0x22), 0xF1, 0x90])
	assert out.len == 13 + 8 + 4 + 4 // ack + the local answer
	diag_to(mut s, default_functional_addr, [u8(0x3E), 0x80])
	assert call.calls == 0
}

fn test_answers_are_framed_from_the_routed_node_and_pending_keeps_the_route_open() {
	mut call := RouteCall{}
	mut s := gateway(mut call)
	diag_to(mut s, zone, [u8(0x31), 0x01, 0xFF, 0x00])
	assert s.route_open
	mut out := [max_resp]u8{}
	pending := [u8(0x7F), 0x31, 0x78]
	mut n := s.routed_message(zone, &pending[0], pending.len, &out[0])
	assert n == 8 + 4 + 3
	assert out[2] == 0x80 && out[3] == 0x01
	assert (u16(out[8]) << 8 | out[9]) == zone
	assert (u16(out[10]) << 8 | out[11]) == tester
	assert out[12] == 0x7F && out[14] == 0x78
	assert s.route_open // the final answer is still to come
	final := [u8(0x71), 0x01, 0xFF, 0x00]
	n = s.routed_message(zone, &final[0], final.len, &out[0])
	assert n == 8 + 4 + 4
	assert !s.route_open
}

fn test_entity_status_reports_a_gateway_when_it_routes() {
	mut call := RouteCall{}
	mut s := gateway(mut call)
	mut resp := [64]u8{}
	assert s.info_response(pt_status_req, 1, &resp[0], 0) == 8 + 7
	assert resp[8] == node_type_gateway
	s.n_routes = 0
	s.info_response(pt_status_req, 1, &resp[0], 0)
	assert resp[8] == node_type_node
}

fn test_route_index_finds_each_routed_address() {
	mut call := RouteCall{}
	s := gateway(mut call)
	assert s.route_index(0x07B0) == 0
	assert s.route_index(zone) == 1
	assert s.route_index(gw) == -1
}

fn test_a_refused_routed_request_leaves_the_forwarded_ones_ticket() {
	mut call := RouteCall{}
	mut s := gateway(mut call)
	diag_to(mut s, zone, [u8(0x36), 0x01, 0xAA])
	assert s.ticket == 1
	call.code = int(dnack_out_of_memory) // the router is still sending that one
	diag_to(mut s, zone, [u8(0x3E), 0x00])
	assert call.ticket == 2 // offered as the next
	assert s.ticket == 1 // ... but the latest is still the one forwarded: its answers go out
	assert s.route_open
}
