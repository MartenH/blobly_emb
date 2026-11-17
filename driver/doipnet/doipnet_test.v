module doipnet

import comm.doip
import os

// The DoIP network loop against a scripted stream: what a pass sends, when it drops the
// connection, and what it reports about routing activation — the same loop the application's
// doip thread and the bootloader's run on the target. @verifies REQ-NET-007

struct Fake {
mut:
	chunks    [][]u8 // what each recv delivers; an empty chunk = the connection dropped
	at        int
	sent      [][]u8
	fail_send int // the send number (1-based) that fails; 0 = none
	drops     int
	act       []bool
	offered   []int // the room each recv was offered
}

fn (mut f Fake) recv(buf &u8, max int) int {
	f.offered << max
	if f.at >= f.chunks.len {
		return 0
	}
	c := f.chunks[f.at]
	f.at++
	if c.len == 0 {
		return -1
	}
	assert c.len <= max
	for i, b in c {
		unsafe {
			buf[i] = b
		}
	}
	return c.len
}

fn (mut f Fake) send(buf &u8, n int) int {
	if f.sent.len + 1 == f.fail_send {
		f.sent << []u8{}
		return -1
	}
	mut b := []u8{len: n}
	for i in 0 .. n {
		b[i] = unsafe { buf[i] }
	}
	f.sent << b
	return n
}

fn (mut f Fake) drop() {
	f.drops++
}

fn (mut f Fake) activated(on bool) {
	f.act << on
}

fn msg(ptype u16, payload []u8) []u8 {
	mut m := [u8(0x02), 0xFD, u8(ptype >> 8), u8(ptype), 0, 0, u8(payload.len >> 8), u8(payload.len)]
	m << payload
	return m
}

fn activation() []u8 {
	return msg(0x0005, [u8(0x0E), 0x00, 0x00, 0, 0, 0, 0])
}

fn diag(uds []u8) []u8 {
	mut p := [u8(0x0E), 0x00, 0x07, 0xA0]
	p << uds
	return msg(0x8001, p)
}

// echoes the request back with its SID + 0x40, like a positive answer
fn echo(_ voidptr, req &u8, n int, _ bool, resp &u8, _ int) int {
	for i in 0 .. n {
		unsafe {
			resp[i] = req[i]
		}
	}
	unsafe {
		resp[0] += 0x40
	}
	return n
}

// the sizes of an entity at the default maximum message length
const max_uds = 520
// spelled out because a fixed array's size must be a constant expression; held to doip.msg_len /
// resp_len by test_the_buffer_sizes_are_the_entitys
const max_msg = doip.header_len + 4 + max_uds
const max_resp = doip.header_len + 5 + doip.header_len + 4 + max_uds

// bound: an entity whose assembly buffer, its own, holds a max_uds message
fn bound() doip.Server {
	mut s := doip.Server{}
	buf := []u8{len: doip.msg_len(max_uds)}
	s.bind(&buf[0], max_uds)
	return s
}

fn entity() doip.Server {
	mut s := bound()
	s.entity_addr = 0x07A0
	s.serve.answer = echo
	return s
}

struct Bufs {
mut:
	inb [max_msg]u8
	out [max_resp]u8
}

fn test_activation_then_a_request_in_one_receive() {
	mut s := entity()
	mut b := Bufs{}
	mut chunk := activation()
	chunk << diag([u8(0x22), 0xF1, 0x90])
	mut f := Fake{
		chunks: [chunk]
	}
	pass(mut f, mut s, &b.inb[0], &b.out[0])
	// the activation answer, then — the response buffer holding one worst-case answer at a
	// time — the ack and the answer, sent before the next message is served
	assert f.sent.len == 2
	assert f.sent[0].len == 8 + 9
	assert f.sent[1].len == (8 + 5) + (8 + 4 + 3)
	assert f.sent[1][12] == 0x00 // positive ack
	assert f.sent[1][13 + 12] == 0x62
	assert f.act == [true]
	assert f.drops == 0
}

fn test_a_request_split_across_receives_is_served_once_whole() {
	mut s := entity()
	mut b := Bufs{}
	req := diag([u8(0x22), 0xF1, 0x90])
	mut f := Fake{
		chunks: [activation(), req[..5], req[5..]]
	}
	for _ in 0 .. 3 {
		pass(mut f, mut s, &b.inb[0], &b.out[0])
	}
	assert f.sent.len == 2
	assert f.sent[1].len == (8 + 5) + (8 + 4 + 3)
	assert f.act == [true, true, true]
}

fn test_a_dropped_connection_starts_the_next_one_unactivated() {
	mut s := entity()
	mut b := Bufs{}
	mut f := Fake{
		chunks: [activation(), []u8{}, diag([u8(0x22), 0xF1, 0x90])]
	}
	for _ in 0 .. 3 {
		pass(mut f, mut s, &b.inb[0], &b.out[0])
	}
	assert !s.activated
	assert f.act == [true, false, false]
	// the request on the new connection is refused: routing is not active there
	assert f.sent.len == 2
	assert f.sent[1][2] == 0x80 && f.sent[1][3] == 0x03 // diagnostic NACK
}

fn test_a_failed_send_ends_the_connection() {
	mut s := entity()
	mut b := Bufs{}
	mut f := Fake{
		chunks:    [activation()]
		fail_send: 1
	}
	pass(mut f, mut s, &b.inb[0], &b.out[0])
	assert !s.activated
	assert s.buf_len == 0
	assert f.act == [false, false]
	assert f.drops == 0 // the C side recycled it already
}

fn test_a_desynced_stream_is_dropped_after_its_nack() {
	mut s := entity()
	mut b := Bufs{}
	mut f := Fake{
		chunks: [[u8(0x01), 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]]
	}
	pass(mut f, mut s, &b.inb[0], &b.out[0])
	assert f.sent.len == 1 && f.sent[0].len == 9 // generic NACK, incorrect pattern
	assert f.drops == 1
	assert !s.fatal && s.buf_len == 0
	assert f.act == [false, false]
}

// a receive never asks for more than the assembly buffer can take
fn test_receive_is_bounded_by_the_assembly_room() {
	mut s := entity()
	mut b := Bufs{}
	req := diag([]u8{len: 100, init: 0x22})
	mut f := Fake{
		chunks: [activation(), req[..20], req[20..]]
	}
	for _ in 0 .. 3 {
		pass(mut f, mut s, &b.inb[0], &b.out[0])
	}
	assert f.offered == [max_msg, max_msg, max_msg - 20]
	assert s.buf_len == 0
	assert f.sent.len == 2
}

// @verifies REQ-CAN-TP-023
// a message longer than the entity assembles is refused with the generic NACK 0x02 as soon as its
// header is in, and discarded as its bytes arrive: the connection stays open (ISO 13400-2's
// generic header handler), and the next message — arriving in the receive that ends the refused
// one — is served
fn test_a_message_too_large_is_refused_and_skipped_on_an_open_connection() {
	mut s := entity()
	mut b := Bufs{}
	big := diag([]u8{len: max_uds + 1, init: 0x2E})
	assert big.len == max_msg + 1
	mut tail := big[500..].clone()
	tail << diag([u8(0x3E), 0x00])
	mut f := Fake{
		chunks: [activation(), big[..8], big[8..500], tail]
	}
	for _ in 0 .. 4 {
		pass(mut f, mut s, &b.inb[0], &b.out[0])
	}
	assert f.drops == 0 && s.activated && !s.fatal
	assert f.sent.len == 3
	assert f.sent[1].len == 9 && f.sent[1][2] == 0x00 && f.sent[1][3] == 0x00 && f.sent[1][8] == 0x02
	assert f.sent[2].len == (8 + 5) + (8 + 4 + 2) && f.sent[2][13 + 12] == 0x7E
	assert s.buf_len == 0 && s.skip == 0
}

// a connection that drops mid-message leaves nothing of it for the next connection
fn test_a_partial_message_dies_with_its_connection() {
	mut s := entity()
	mut b := Bufs{}
	req := diag([u8(0x22), 0xF1, 0x90])
	mut f := Fake{
		chunks: [activation(), req[..5], []u8{}, activation()]
	}
	for _ in 0 .. 4 {
		pass(mut f, mut s, &b.inb[0], &b.out[0])
	}
	assert f.sent.len == 2
	assert f.sent[1].len == 8 + 9 && f.sent[1][12] == 0x10 // the new connection activates
	assert f.act == [true, true, false, true]
}

// a response the server pushes (a routine's next responsePending) goes to the activated tester; with
// none activated its connection is gone and nothing is sent; a failed send ends the connection
fn test_a_pushed_response_goes_to_the_activated_tester() {
	mut s := entity()
	mut b := Bufs{}
	pending := [u8(0x7F), 0x31, 0x78]
	mut f := Fake{}
	assert !push(mut f, mut s, &pending[0], 3, &b.out[0])
	assert f.sent.len == 0, 'no tester activated'
	f.chunks = [activation()]
	pass(mut f, mut s, &b.inb[0], &b.out[0])
	assert push(mut f, mut s, &pending[0], 3, &b.out[0])
	assert f.sent.len == 2 && f.sent[1] == [u8(0x02), 0xFD, 0x80, 0x01, 0, 0, 0, 7, 0x07, 0xA0, 0x0E,
		0x00, 0x7F, 0x31, 0x78]
	f.fail_send = 3
	assert !push(mut f, mut s, &pending[0], 3, &b.out[0])
	assert !s.activated && f.act.last() == false
}

// A gateway's routed answers (REQ-NET-019): only the latest routed request's, only to its tester
// while connected, framed from the routed node.
// @verifies REQ-NET-019
fn routed_gateway() doip.Server {
	mut s := bound()
	s.entity_addr = 0x07A0
	s.activated = true
	s.tester_addr = 0x0E00
	s.ticket = 4
	s.route_open = true
	return s
}

fn test_a_routed_answer_goes_to_the_tester_from_the_routed_node() {
	mut f := Fake{}
	mut s := routed_gateway()
	mut out := [max_resp]u8{}
	ans := [u8(0x62), 0xF1, 0x90, 0x5A]
	assert routed(mut f, mut s, 0x07C0, 4, &ans[0], ans.len, &out[0])
	assert f.sent.len == 1
	m := f.sent[0]
	assert m[2] == 0x80 && m[3] == 0x01
	assert (u16(m[8]) << 8 | m[9]) == 0x07C0
	assert (u16(m[10]) << 8 | m[11]) == 0x0E00
	assert m[12..] == ans
	assert !s.route_open
}

fn test_an_answer_to_an_earlier_request_or_connection_is_no_ones() {
	mut f := Fake{}
	mut s := routed_gateway()
	mut out := [max_resp]u8{}
	ans := [u8(0x7E), 0x00]
	assert !routed(mut f, mut s, 0x07C0, 3, &ans[0], ans.len, &out[0]) // the tester moved on
	s.activated = false
	assert !routed(mut f, mut s, 0x07C0, 4, &ans[0], ans.len, &out[0]) // its connection is gone
	s.activated = true
	s.route_open = false // the poll budget ran out: the tester's P6* long before it
	assert !routed(mut f, mut s, 0x07C0, 4, &ans[0], ans.len, &out[0])
	assert f.sent.len == 0
}

// a responsePending keeps the answer due, so the final answer after it is still taken
fn test_the_answer_after_a_response_pending_is_still_taken() {
	mut f := Fake{}
	mut s := routed_gateway()
	mut out := [max_resp]u8{}
	pending := [u8(0x7F), 0x31, 0x78]
	final := [u8(0x71), 0x01, 0xFF, 0x00]
	assert routed(mut f, mut s, 0x07C0, 4, &pending[0], pending.len, &out[0])
	assert s.route_open
	assert routed(mut f, mut s, 0x07C0, 4, &final[0], final.len, &out[0])
	assert !s.route_open && f.sent.len == 2
}

fn test_a_new_connection_has_a_new_number_and_no_routed_answer_due() {
	mut f := Fake{}
	mut s := routed_gateway()
	before := s.conn
	end(mut f, mut s)
	assert s.conn == before + 1
	assert !s.route_open
}

fn test_the_routers_verdicts_are_diagnostic_nack_codes() {
	assert verdict_code(.accepted) == 0
	assert verdict_code(.unknown_target) == int(doip.dnack_unknown_target)
	assert verdict_code(.locked) == int(doip.dnack_unreachable)
	assert verdict_code(.busy) == int(doip.dnack_out_of_memory)
	assert verdict_code(.too_large) == int(doip.dnack_too_large)
	assert verdict_code(.refused) == int(doip.dnack_transport_error)
}

fn test_an_answer_due_when_the_connection_ends_never_reaches_the_next_tester() {
	mut f := Fake{}
	mut s := routed_gateway()
	mut out := [max_resp]u8{}
	due := s.ticket
	end(mut f, mut s)
	// the next tester activates on a fresh connection, without the gateway's unlock
	s.activated = true
	ans := [u8(0x62), 0xF1, 0x90, 0x5A]
	assert !routed(mut f, mut s, 0x07C0, due, &ans[0], ans.len, &out[0])
	assert f.sent.len == 0
}

// @verifies REQ-CAN-TP-023
// the loop follows the entity's maximum message: at 4095 a receive is offered the whole assembly
// room and a 4095-byte request is served whole, through a response buffer of the entity's size
fn test_the_loop_follows_the_entitys_maximum_message() {
	mut s := doip.Server{}
	big := []u8{len: doip.msg_len(4095)}
	s.bind(&big[0], 4095)
	s.entity_addr = 0x07A0
	s.serve.answer = echo
	inb := []u8{len: s.msg_cap()}
	out := []u8{len: s.resp_cap()}
	req := diag([]u8{len: 4095, init: 0x22})
	mut f := Fake{
		chunks: [activation(), req]
	}
	for _ in 0 .. 2 {
		pass(mut f, mut s, &inb[0], &out[0])
	}
	assert f.offered == [doip.msg_len(4095), doip.msg_len(4095)]
	assert f.sent.len == 2 && f.sent[1].len == 13 + 12 + 4095
}

// @verifies REQ-CAN-TP-023
// a routed answer is framed up to the entity's limit and no further: one of max_uds goes to the
// tester, one byte more is not framed (the response buffer holds a max_uds message) and the answer
// stays due
fn test_a_routed_answer_past_the_entitys_limit_is_not_framed() {
	mut f := Fake{}
	mut s := routed_gateway()
	mut out := [max_resp]u8{}
	mut ans := []u8{len: max_uds + 1, init: u8(index)}
	ans[0] = 0x62
	assert !routed(mut f, mut s, 0x07C0, 4, unsafe { &ans[0] }, ans.len, &out[0])
	assert f.sent.len == 0 && s.route_open
	assert routed(mut f, mut s, 0x07C0, 4, unsafe { &ans[0] }, max_uds, &out[0])
	assert f.sent.len == 1 && f.sent[0][12..] == ans[..max_uds]
}

fn test_the_buffer_sizes_are_the_entitys() {
	assert max_msg == doip.msg_len(max_uds)
	assert max_resp == doip.resp_len(max_uds)
}


// The push slot is one size in both halves: doip_netx.c's MB_PUSH_MAX (what doip_mb_push_resp takes)
// and push_max, which sizes the doip thread's buffer (a larger push_max with a smaller buffer would
// leave a push the buffer cannot take for ever).
fn test_the_push_slot_is_one_size() {
	c := os.read_file(os.join_path(@VMODROOT, 'driver', 'eth', 'doip_netx.c')) or { panic(err) }
	line := c.split_into_lines().filter(it.starts_with('#define MB_PUSH_MAX '))
	assert line.len == 1
	assert line[0].all_after('#define MB_PUSH_MAX ').trim_space().int() == push_max
	v := os.read_file(os.join_path(@VMODROOT, 'driver', 'doipnet', 'netx_d_freestanding.v')) or {
		panic(err)
	}
	assert v.contains('mut pushed := [push_max]u8{}')
}
