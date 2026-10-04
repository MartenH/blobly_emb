module doipnet

import comm.doip

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
fn echo(ctx voidptr, req &u8, n int, functional bool, resp &u8, cap int) int {
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

fn entity() doip.Server {
	mut s := doip.Server{}
	s.entity_addr = 0x07A0
	s.serve.answer = echo
	return s
}

struct Bufs {
mut:
	inb [doip.max_msg]u8
	out [doip.max_resp]u8
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
	assert f.offered == [doip.max_msg, doip.max_msg, doip.max_msg - 20]
	assert s.buf_len == 0
	assert f.sent.len == 2
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
