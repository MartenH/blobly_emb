module diagroute

// The router between a DoIP tester and a node behind the gateway, against a scripted node on its
// own ISO-TP link: what is forwarded, what comes back and in which order, how long the gateway
// waits, and who may route at all.
// @verifies REQ-NET-019 REQ-NET-020 REQ-NET-021 REQ-CAN-TP-042
import comm.isotp
import comm.uds
import driver.can

const la = u16(0x07C0)
const req_id = u32(0x7C0)
const rsp_id = u32(0x7C8)
const edge = u8(1)

// Chan is a bus as the router sees it: what it sends is recorded
struct Chan {
mut:
	tx      []can.Frame
	refuse  bool
	stalled bool // the controller takes no frame (a full transmit FIFO)
}

pub fn (mut c Chan) tx_ready() bool {
	return !c.stalled
}

pub fn (mut c Chan) send(f can.Frame) bool {
	if c.refuse {
		return false
	}
	c.tx << f
	return true
}

// Node is the routed target: its own link on the bus, answering what a script says
struct Node {
mut:
	link     isotp.Link
	requests [][]u8
}

fn new_node() Node {
	mut n := Node{}
	n.link.bs = 0
	n.link.init_defaults()
	rxb := []u8{len: isotp.message_limit}
	txb := []u8{len: isotp.message_limit}
	n.link.bind_rx(&rxb[0], isotp.message_limit)
	n.link.bind_tx(&txb[0], isotp.message_limit)
	return n
}

fn new_router() Router {
	return router_at(isotp.default_message)
}

// router_at: a router of the gateway's maximum message `m`, its storage the owner's
fn router_at(m int) Router {
	mut r := Router{}
	storage := []u8{len: storage_len(m)}
	r.init(1, 8, &storage[0], m)
	assert r.add(Route{
		logical: la
		bus:     edge
		tx_id:   req_id
		rx_id:   rsp_id
	})
	return r
}

// frame: a PDU as the frame it goes out as on `id`, at its length (a hand-built one's 0 as 8)
fn frame(id u32, p isotp.Pdu) can.Frame {
	n := if p.len == 0 { 8 } else { p.len }
	mut f := can.Frame{
		id:  id
		len: u8(n)
	}
	for i in 0 .. n {
		f.data[i] = p.data[i]
	}
	return f
}

// pdu: a frame as a link reads it, at its length
fn pdu(f can.Frame) isotp.Pdu {
	mut p := isotp.Pdu{
		len: int(f.len)
	}
	for i in 0 .. int(f.len) {
		p.data[i] = f.data[i]
	}
	return p
}

// pass: one owner pass — the router's frames go on the bus to the node, the node's back
fn pass(mut r Router, mut n Node, mut ch Chan, now u64) {
	r.step(now)
	r.pump(now, mut ch)
	for f in ch.tx {
		assert f.id == req_id
		n.link.on_frame(now, pdu(f))
	}
	ch.tx.clear()
	if n.link.has_request() {
		mut buf := []u8{len: isotp.message_limit}
		got := n.link.take(unsafe { &buf[0] })
		n.requests << buf[..got]
	}
	mut p := isotp.Pdu{}
	for n.link.poll(now, mut p) {
		f := frame(rsp_id, p)
		r.on_frame(edge, &f, now)
	}
}

fn answer(mut n Node, data []u8) {
	assert n.link.send(&data[0], data.len)
}

fn take(mut r Router) []u8 {
	assert r.waiting() > 0
	a := r.head()
	out := unsafe { a.data.vbytes(a.len) }.clone()
	r.pop()
	return out
}

fn run(mut r Router, mut n Node, mut ch Chan, mut now &u64, passes int) {
	for _ in 0 .. passes {
		unsafe {
			*now += 1000
		}
		pass(mut r, mut n, mut ch, *now)
	}
}

fn test_a_tester_without_the_gateways_unlock_is_not_routed() {
	mut r := new_router()
	req := [u8(0x22), 0xF1, 0x90]
	assert r.accept(0, &req[0], req.len, 1, 1, 0, u64(0)) == .locked
	assert r.accept(0, &req[0], req.len, 1, 2, 2, u64(0)) == .locked // another level is not the one routing needs
	assert r.accept(0, &req[0], req.len, 1, 3, 1, u64(0)) == .accepted
	assert r.forwarded == 1
}

fn test_the_grant_lasts_the_connection_not_the_session() {
	mut r := new_router()
	mut n := new_node()
	mut ch := Chan{}
	mut now := u64(0)
	req := [u8(0x3E), 0x00]
	assert r.accept(0, &req[0], req.len, 7, 1, 1, now) == .accepted
	run(mut r, mut n, mut ch, mut &now, 3)
	answer(mut n, [u8(0x7E), 0x00])
	run(mut r, mut n, mut ch, mut &now, 3)
	assert take(mut r) == [u8(0x7E), 0x00]
	// the gateway's session ended meanwhile (its unlock with it): the same connection still routes
	assert r.accept(0, &req[0], req.len, 7, 2, 0, now) == .accepted
	// a new connection does not inherit the grant
	run(mut r, mut n, mut ch, mut &now, 3)
	assert r.accept(0, &req[0], req.len, 8, 3, 0, now) == .locked
}

fn test_an_unknown_route_is_refused() {
	mut r := new_router()
	req := [u8(0x3E), 0x00]
	assert r.accept(1, &req[0], req.len, 1, 1, 1, u64(0)) == .unknown_target
	assert r.accept(-1, &req[0], req.len, 1, 1, 1, u64(0)) == .unknown_target
	assert r.find(la) == 0
	assert r.find(0x07B0) == -1
}

fn test_a_single_frame_exchange_comes_back_from_the_targets_address() {
	mut r := new_router()
	mut n := new_node()
	mut ch := Chan{}
	mut now := u64(0)
	req := [u8(0x22), 0xF1, 0x90]
	assert r.accept(0, &req[0], req.len, 1, 42, 1, now) == .accepted
	assert r.active_bus() == int(edge)
	run(mut r, mut n, mut ch, mut &now, 2)
	assert n.requests == [[u8(0x22), 0xF1, 0x90]]
	answer(mut n, [u8(0x62), 0xF1, 0x90, 0x41])
	run(mut r, mut n, mut ch, mut &now, 2)
	assert r.waiting() == 1
	a := r.head()
	assert a.logical == la
	assert a.ticket == 42
	assert take(mut r) == [u8(0x62), 0xF1, 0x90, 0x41]
	assert !r.busy() // the final answer ended the exchange
	assert r.answered == 1
}

fn test_a_transfer_block_goes_out_and_a_long_answer_comes_back_under_flow_control() {
	mut r := new_router()
	mut n := new_node()
	mut ch := Chan{}
	mut now := u64(0)
	mut block := [u8(0x36), 0x01]
	for i in 0 .. 512 {
		block << u8(i)
	}
	assert r.accept(0, unsafe { &block[0] }, block.len, 1, 1, 1, now) == .accepted
	// a multi-frame request is still being sent: the next one would be busy
	assert r.accept(0, unsafe { &block[0] }, 3, 1, 2, 1, now) == .busy
	run(mut r, mut n, mut ch, mut &now, 120)
	assert n.requests.len == 1
	assert n.requests[0] == block
	mut long := [u8(0x76), 0x01] // TransferData's answer, long (a node may echo data with it)
	for i in 0 .. 200 {
		long << u8(255 - i % 256)
	}
	answer(mut n, long)
	run(mut r, mut n, mut ch, mut &now, 120)
	assert take(mut r) == long
}

fn test_response_pending_keeps_the_exchange_open_and_both_answers_come_back_in_order() {
	mut r := new_router()
	mut n := new_node()
	mut ch := Chan{}
	mut now := u64(0)
	req := [u8(0x31), 0x01, 0xFF, 0x00]
	assert r.accept(0, &req[0], req.len, 1, 5, 1, now) == .accepted
	run(mut r, mut n, mut ch, mut &now, 2)
	answer(mut n, [u8(0x7F), 0x31, 0x78])
	run(mut r, mut n, mut ch, mut &now, 2)
	assert r.busy()
	// longer than one answer wait after the request, within one after the responsePending
	now += answer_wait_us - 10_000
	run(mut r, mut n, mut ch, mut &now, 2)
	answer(mut n, [u8(0x71), 0x01, 0xFF, 0x00])
	run(mut r, mut n, mut ch, mut &now, 2)
	assert take(mut r) == [u8(0x7F), 0x31, 0x78]
	assert take(mut r) == [u8(0x71), 0x01, 0xFF, 0x00]
	assert r.timeouts == 0
	assert !r.busy()
}

// @verifies REQ-DIAG-086
// A routine answered responsePending several times — 0/4/8 s, as an application server repeats it
// (uds.pending_repeat_us), the final answer at 11 s, longer than one answer wait — reaches the
// tester whole: each 0x78 forwarded in order and renewing the wait, the exchange ended by the final
// answer alone.
fn test_several_responses_pending_keep_a_long_exchange_open() {
	assert uds.pending_repeat_us < answer_wait_us
	assert answer_wait_us == uds.p2_star_server_us + 1_000_000
	mut r := new_router()
	mut n := new_node()
	mut ch := Chan{}
	mut now := u64(0)
	req := [u8(0x31), 0x01, 0x02, 0x01, 0x5A]
	assert r.accept(0, &req[0], req.len, 1, 9, 1, now) == .accepted
	run(mut r, mut n, mut ch, mut &now, 2)
	assert n.requests == [req]
	t_req := now
	for k in 0 .. 3 {
		for now < t_req + u64(k) * uds.pending_repeat_us {
			run(mut r, mut n, mut ch, mut &now, 1)
		}
		answer(mut n, [u8(0x7F), 0x31, 0x78])
		run(mut r, mut n, mut ch, mut &now, 2)
		assert r.live_ticket() == 9, 'the exchange ended at responsePending ${k + 1}'
		assert take(mut r) == [u8(0x7F), 0x31, 0x78]
	}
	for now < t_req + 11_000_000 {
		run(mut r, mut n, mut ch, mut &now, 1)
		assert r.live_ticket() == 9, 'the wait ran out at ${now - t_req} us'
	}
	answer(mut n, [u8(0x71), 0x01, 0x02, 0x01, 0x02, 0x00, 0xB4])
	run(mut r, mut n, mut ch, mut &now, 2)
	assert take(mut r) == [u8(0x71), 0x01, 0x02, 0x01, 0x02, 0x00, 0xB4]
	assert r.waiting() == 0
	assert r.timeouts == 0
	assert r.live_ticket() == 0, 'the final answer ends the exchange'
}

fn test_an_unanswered_exchange_ends_after_the_answer_wait() {
	mut r := new_router()
	mut n := new_node()
	mut ch := Chan{}
	mut now := u64(0)
	req := [u8(0x22), 0xF1, 0x95]
	assert r.accept(0, &req[0], req.len, 1, 1, 1, now) == .accepted
	run(mut r, mut n, mut ch, mut &now, 2)
	assert r.live_ticket() == 1 // waiting for the answer
	now += answer_wait_us
	run(mut r, mut n, mut ch, mut &now, 1)
	assert r.timeouts == 1
	assert !r.busy()
	assert r.live_ticket() == 0 // let go: the transport's own budget runs from here
	// an answer after the exchange ended is no one's
	answer(mut n, [u8(0x62), 0xF1, 0x95, 0x01])
	run(mut r, mut n, mut ch, mut &now, 2)
	assert r.waiting() == 0
}

fn test_the_next_request_supersedes_a_wait_and_drops_its_queued_answers() {
	mut r := new_router()
	mut n := new_node()
	mut ch := Chan{}
	mut now := u64(0)
	a := [u8(0x31), 0x01, 0xFF, 0x00]
	assert r.accept(0, &a[0], a.len, 1, 1, 1, now) == .accepted
	run(mut r, mut n, mut ch, mut &now, 2)
	answer(mut n, [u8(0x7F), 0x31, 0x78])
	run(mut r, mut n, mut ch, mut &now, 2)
	assert r.waiting() == 1 // not yet taken by the doip thread
	b := [u8(0x3E), 0x00]
	assert r.accept(0, &b[0], b.len, 1, 2, 1, now) == .accepted
	assert r.waiting() == 0
	assert r.live_ticket() == 2 // the new request's, never the superseded one's
	run(mut r, mut n, mut ch, mut &now, 2)
	answer(mut n, [u8(0x7E), 0x00])
	run(mut r, mut n, mut ch, mut &now, 2)
	got := r.head()
	assert got.ticket == 2
	assert take(mut r) == [u8(0x7E), 0x00]
}

fn test_frames_of_another_bus_id_or_format_are_not_the_routes() {
	mut r := new_router()
	req := [u8(0x3E), 0x00]
	assert r.accept(0, &req[0], req.len, 1, 1, 1, u64(0)) == .accepted
	mut ch := Chan{}
	r.pump(500, mut ch) // the request out: what comes now is its answer
	mut f := can.Frame{
		id:  rsp_id
		len: 8
	}
	f.data[0] = 0x02
	f.data[1] = 0x7E
	assert !r.on_frame(0, &f, 1000) // the compute bus
	f.id = 0x7A8
	assert !r.on_frame(edge, &f, 1000) // another node's answer
	f.id = rsp_id
	f.ext = true
	assert !r.on_frame(edge, &f, 1000) // the response number as a 29-bit id: another frame
	f.ext = false
	assert r.on_frame(edge, &f, 1000)
	assert r.waiting() == 1
}

fn test_with_no_exchange_nothing_is_taken() {
	mut r := new_router()
	mut f := can.Frame{
		id:  rsp_id
		len: 8
	}
	f.data[0] = 0x02
	f.data[1] = 0x7E
	assert !r.on_frame(edge, &f, 1000)
	assert r.active_bus() == -1
}

fn test_answers_beyond_the_queue_are_counted_lost() {
	mut r := new_router()
	req := [u8(0x31), 0x01, 0xFF, 0x00]
	assert r.accept(0, &req[0], req.len, 1, 1, 1, u64(0)) == .accepted
	mut ch := Chan{}
	r.pump(500, mut ch)
	mut f := can.Frame{
		id:  rsp_id
		len: 8
	}
	f.data[0] = 0x03
	f.data[1] = 0x7F
	f.data[2] = 0x31
	f.data[3] = 0x78
	for _ in 0 .. queue_len {
		assert r.on_frame(edge, &f, 1000)
	}
	assert r.full()
	assert r.on_frame(edge, &f, 1000)
	assert r.lost == 1
	assert r.waiting() == queue_len
}

fn test_a_refused_frame_ends_the_exchange() {
	mut r := new_router()
	mut ch := Chan{
		refuse: true
	}
	req := [u8(0x3E), 0x00]
	assert r.accept(0, &req[0], req.len, 1, 1, 1, u64(0)) == .accepted
	r.pump(1000, mut ch)
	assert !r.busy()
}

fn test_an_empty_or_oversized_request_is_refused() {
	mut r := new_router()
	req := []u8{len: isotp.default_message + 1}
	assert r.accept(0, &req[0], 0, 1, 1, 1, u64(0)) == .refused
	assert r.accept(0, &req[0], req.len, 1, 1, 1, u64(0)) == .too_large
}

// A tester without the gateway's unlock learns nothing of a route (REQ-NET-020), its size included:
// an oversized request is locked out like any other, and too_large only once the unlock is held.
fn test_a_locked_tester_is_refused_before_the_size_is_judged() {
	mut r := new_router()
	big := []u8{len: isotp.default_message + 1}
	assert r.accept(0, &big[0], big.len, 1, 1, 0, u64(0)) == .locked
	assert r.accept(0, &big[0], big.len, 1, 2, 1, u64(0)) == .too_large
}

fn test_the_table_holds_each_address_once() {
	mut r := new_router()
	assert !r.add(Route{
		logical: la
		bus:     0
		tx_id:   0x7B0
		rx_id:   0x7B8
	})
	for i in 1 .. max_routes {
		assert r.add(Route{
			logical: u16(0x1000 + i)
			bus:     edge
			tx_id:   u32(0x700 + i)
			rx_id:   u32(0x780 + i)
		})
	}
	assert !r.add(Route{
		logical: 0x2000
		bus:     edge
		tx_id:   0x6F0
		rx_id:   0x6F8
	})
}

fn test_a_late_answer_does_not_complete_a_request_still_leaving() {
	mut r := new_router()
	mut f := can.Frame{
		id:  rsp_id
		len: 8
	}
	mut block := [u8(0x36), 0x01]
	for i in 0 .. 100 {
		block << u8(i)
	}
	assert r.accept(0, unsafe { &block[0] }, block.len, 1, 2, 1, 0) == .accepted
	mut ch := Chan{}
	r.pump(1000, mut ch) // the first frame out: the request now waits for flow control
	// the answer to the request the tester gave up on, still in the bus's FIFO
	f.data[0] = 0x02
	f.data[1] = 0x7E
	assert r.on_frame(edge, &f, 1000) // the route's id: the router's, and dropped
	assert r.waiting() == 0
	assert r.busy() // the new request goes on
	// its flow control still counts
	f.data[0] = 0x30
	f.data[1] = 0
	f.data[2] = 0
	assert r.on_frame(edge, &f, 1000)
	r.pump(2000, mut ch)
	assert ch.tx.len > 1
}

fn test_a_request_that_cannot_leave_ends_after_the_stall_bound() {
	mut r := new_router()
	req := [u8(0x3E), 0x00]
	assert r.accept(0, &req[0], req.len, 1, 1, 1, 0) == .accepted
	// nothing pumped: the bus took no frame
	r.step(stall_us - 1)
	assert r.busy()
	r.step(stall_us)
	assert !r.busy()
	assert r.timeouts == 1
	assert r.live_ticket() == 0
}

fn test_an_answer_begun_in_time_may_run_past_the_answer_wait() {
	mut r := new_router()
	mut n := new_node()
	mut ch := Chan{}
	mut now := u64(0)
	req := [u8(0x22), 0xF1, 0x00]
	assert r.accept(0, &req[0], req.len, 1, 1, 1, now) == .accepted
	run(mut r, mut n, mut ch, mut &now, 2)
	// the target begins a long answer just inside the wait, and sends it slowly
	now += answer_wait_us - 5000
	mut long := [u8(0x62), 0xF1, 0x00]
	for i in 0 .. 60 {
		long << u8(i)
	}
	answer(mut n, long)
	run(mut r, mut n, mut ch, mut &now, 1) // the first frame: the reception has begun
	now += 10_000 // past the wait
	run(mut r, mut n, mut ch, mut &now, 30)
	assert r.timeouts == 0
	assert take(mut r) == long
}

fn test_an_answer_after_the_wait_is_not_taken_whatever_the_order_of_the_pass() {
	mut r := new_router()
	mut n := new_node()
	mut ch := Chan{}
	mut now := u64(0)
	req := [u8(0x22), 0xF1, 0x95]
	assert r.accept(0, &req[0], req.len, 1, 1, 1, now) == .accepted
	run(mut r, mut n, mut ch, mut &now, 2)
	// a frame drained before this pass's step, after the wait ran out
	mut f := can.Frame{
		id:  rsp_id
		len: 8
	}
	f.data[0] = 0x03
	f.data[1] = 0x7F
	f.data[2] = 0x22
	f.data[3] = 0x78
	assert !r.on_frame(edge, &f, now + answer_wait_us)
	assert r.waiting() == 0
	assert r.timeouts == 1
	assert !r.busy()
}

fn test_a_request_that_has_left_is_not_busy_before_the_next_step() {
	mut r := new_router()
	mut ch := Chan{}
	req := [u8(0x3E), 0x80] // suppressed: no answer comes
	assert r.accept(0, &req[0], req.len, 1, 1, 1, 0) == .accepted
	r.pump(1000, mut ch) // the single frame left; no step since
	assert r.accept(0, &req[0], req.len, 1, 2, 1, 2000) == .accepted
}

fn test_an_answer_to_another_request_is_dropped_and_this_ones_still_comes() {
	mut r := new_router()
	mut n := new_node()
	mut ch := Chan{}
	mut now := u64(0)
	req := [u8(0x22), 0xF1, 0x90]
	assert r.accept(0, &req[0], req.len, 1, 7, 1, now) == .accepted
	run(mut r, mut n, mut ch, mut &now, 2)
	answer(mut n, [u8(0x71), 0x01, 0xFF, 0x00]) // the routine's late answer, from before
	run(mut r, mut n, mut ch, mut &now, 2)
	assert r.waiting() == 0 && r.stale == 1
	assert r.busy() || r.active_bus() >= 0 // still waiting for its own
	answer(mut n, [u8(0x62), 0xF1, 0x90, 0x41])
	run(mut r, mut n, mut ch, mut &now, 2)
	assert take(mut r) == [u8(0x62), 0xF1, 0x90, 0x41]
	// a negative answer naming the service is this request's too
	neg := [u8(0x7F), 0x22, 0x31]
	other := [u8(0x7F), 0x31, 0x31]
	assert answers(&neg[0], neg.len, &req[0], req.len, req.len)
	assert !answers(&other[0], other.len, &req[0], req.len, req.len)
}

fn test_a_slow_transfer_that_keeps_moving_is_not_cut_off() {
	mut r := new_router()
	mut n := new_node()
	n.link.stmin = 0x7F // the target asks 127 ms between consecutive frames
	mut ch := Chan{}
	mut now := u64(0)
	mut block := [u8(0x36), 0x01]
	for i in 0 .. 512 {
		block << u8(i)
	}
	assert r.accept(0, unsafe { &block[0] }, block.len, 1, 7, 1, now) == .accepted
	// 74 consecutive frames 127 ms apart: about 9.4 s, longer than stall_us — and live throughout,
	// so the transport keeps waiting for the answer past its own fixed budget
	for _ in 0 .. 400 {
		assert r.live_ticket() == 7
		now += 30_000
		pass(mut r, mut n, mut ch, now)
		if n.requests.len > 0 {
			break
		}
	}
	assert n.requests.len == 1 && n.requests[0] == block
	assert now > stall_us
	assert r.timeouts == 0 && r.failed == 0
	assert r.live_ticket() == 7 // its answer is still to come
	answer(mut n, [u8(0x76), 0x01])
	pass(mut r, mut n, mut ch, now + 1000)
	assert take(mut r) == [u8(0x76), 0x01]
	assert r.live_ticket() == 0 // answered: the exchange is over
}

// our flow control for an answer that never leaves ends the exchange at the stall bound even with
// ISO-TP's N_Ar off (n_ar_us 0): the bound is the backstop of a link that does not give up itself —
// N_Ar's own ending is test_an_answer_whose_flow_control_cannot_leave_ends_at_n_ar
fn test_flow_control_that_cannot_leave_ends_the_exchange() {
	mut r := new_router()
	r.link.n_ar_us = 0
	mut n := new_node()
	mut ch := Chan{}
	mut now := u64(0)
	req := [u8(0x22), 0xF1, 0x00]
	assert r.accept(0, &req[0], req.len, 1, 1, 1, now) == .accepted
	run(mut r, mut n, mut ch, mut &now, 2)
	mut long := [u8(0x62), 0xF1, 0x00]
	for i in 0 .. 40 {
		long << u8(i)
	}
	answer(mut n, long)
	ch.stalled = true // the gateway's controller takes nothing: our flow control never leaves
	run(mut r, mut n, mut ch, mut &now, 3)
	r.step(now + 4_000_000) // past N_Ar, short of the stall bound: nothing ended it yet
	assert r.busy() && r.timeouts == 0
	now += stall_us
	r.step(now)
	assert !r.busy()
	assert r.timeouts == 1
}

fn test_a_send_iso_tp_gave_up_on_ends_the_exchange() {
	mut r := new_router()
	mut ch := Chan{}
	mut block := [u8(0x36), 0x01]
	for i in 0 .. 100 {
		block << u8(i)
	}
	assert r.accept(0, unsafe { &block[0] }, block.len, 1, 1, 1, 0) == .accepted
	r.pump(1000, mut ch) // the first frame out; the target never sends flow control
	r.step(2_000_000) // N_Bs ran out: ISO-TP gave up
	assert r.failed == 1
	assert r.active_bus() == -1 // not waiting for an answer to a request never received whole
	assert r.live_ticket() == 0
	mut f := can.Frame{
		id:  rsp_id
		len: 8
	}
	f.data[0] = 0x02
	f.data[1] = 0x76
	assert !r.on_frame(edge, &f, 2_000_100)
	assert r.waiting() == 0
	// the abandoned send is not held against the next exchange, which is routed and answered
	ch.tx.clear()
	mut n := new_node()
	mut now := u64(2_000_100)
	req := [u8(0x22), 0xF1, 0x90]
	assert r.accept(0, &req[0], req.len, 1, 2, 1, now) == .accepted
	run(mut r, mut n, mut ch, mut &now, 2)
	assert n.requests == [req]
	answer(mut n, [u8(0x62), 0xF1, 0x90, 0x41])
	run(mut r, mut n, mut ch, mut &now, 2)
	assert r.failed == 1
	assert take(mut r) == [u8(0x62), 0xF1, 0x90, 0x41]
}

fn test_an_invalid_request_leaves_the_exchange_in_flight_alone() {
	mut r := new_router()
	mut ch := Chan{}
	req := [u8(0x31), 0x01, 0xFF, 0x00]
	assert r.accept(0, &req[0], req.len, 1, 1, 1, 0) == .accepted
	r.pump(500, mut ch)
	r.step(600)
	big := []u8{len: isotp.default_message + 1}
	assert r.accept(0, &big[0], big.len, 1, 2, 1, 700) == .too_large
	assert r.accept(0, &big[0], 0, 1, 3, 1, 800) == .refused
	assert r.active_bus() == int(edge) // still waiting for the routine's answer
}

fn test_a_late_answer_of_the_same_service_is_told_apart_by_what_it_echoes() {
	mut r := new_router()
	mut n := new_node()
	mut ch := Chan{}
	mut now := u64(0)
	req := [u8(0x22), 0xF1, 0x81]
	assert r.accept(0, &req[0], req.len, 1, 2, 1, now) == .accepted
	run(mut r, mut n, mut ch, mut &now, 2)
	answer(mut n, [u8(0x62), 0xF1, 0x90, 0x41]) // F190's answer, to the request the tester gave up on
	run(mut r, mut n, mut ch, mut &now, 2)
	assert r.waiting() == 0 && r.stale == 1
	answer(mut n, [u8(0x62), 0xF1, 0x81, 0x01])
	run(mut r, mut n, mut ch, mut &now, 2)
	assert take(mut r) == [u8(0x62), 0xF1, 0x81, 0x01]
	// what each service echoes
	ok := fn (a []u8, q []u8) bool {
		return answers(&a[0], a.len, &q[0], q.len, q.len)
	}
	assert ok([u8(0x50), 0x03], [u8(0x10), 0x03]) && !ok([u8(0x50), 0x02], [u8(0x10), 0x03])
	assert ok([u8(0x7E), 0x00], [u8(0x3E), 0x80]) // the suppress bit is not echoed
	assert ok([u8(0x71), 0x01, 0xFF, 0x00], [u8(0x31), 0x01, 0xFF, 0x00])
	assert !ok([u8(0x71), 0x01, 0xFF, 0x01], [u8(0x31), 0x01, 0xFF, 0x00])
	assert ok([u8(0x76), 0x05], [u8(0x36), 0x05, 0xAA]) && !ok([u8(0x76), 0x04], [u8(0x36), 0x05, 0xAA])
	assert ok([u8(0x74), 0x20, 0x02, 0x02], [u8(0x34), 0x00, 0x44]) // 0x34 echoes nothing
}

fn test_a_tester_that_went_leaves_no_exchange_and_no_answers() {
	mut r := new_router()
	mut n := new_node()
	mut ch := Chan{}
	mut now := u64(0)
	req := [u8(0x31), 0x01, 0xFF, 0x00]
	assert r.accept(0, &req[0], req.len, 1, 1, 1, now) == .accepted
	run(mut r, mut n, mut ch, mut &now, 2)
	answer(mut n, [u8(0x7F), 0x31, 0x78])
	run(mut r, mut n, mut ch, mut &now, 2)
	assert r.waiting() == 1
	assert r.live_ticket() == 1 // a responsePending: the final answer is still to come
	r.cancel()
	assert r.waiting() == 0 && !r.busy() && r.active_bus() == -1
	assert r.live_ticket() == 0
	// and the next connection starts unrouted
	assert r.accept(0, &req[0], req.len, 1, 2, 0, now) == .locked
}

fn test_a_full_queue_holds_the_bus_only_briefly() {
	mut r := new_router()
	req := [u8(0x31), 0x01, 0xFF, 0x00]
	assert r.accept(0, &req[0], req.len, 1, 1, 1, 0) == .accepted
	mut ch := Chan{}
	r.pump(100, mut ch)
	mut f := can.Frame{
		id:  rsp_id
		len: 8
	}
	f.data[0] = 0x03
	f.data[1] = 0x7F
	f.data[2] = 0x31
	f.data[3] = 0x78
	assert r.room(1000)
	for _ in 0 .. queue_len {
		assert r.on_frame(edge, &f, 1000)
	}
	assert !r.room(1000) // full: the bus waits for the doip thread...
	assert !r.room(1000 + gate_hold_us - 1)
	assert r.room(1000 + gate_hold_us) // ... but no longer than gate_hold_us
	r.pop()
	assert r.room(1000 + gate_hold_us + 1)
}

fn test_flow_control_alone_does_not_count_as_progress() {
	mut r := new_router()
	mut ch := Chan{
		stalled: true // the request's single frame cannot leave
	}
	req := [u8(0x22), 0xF1, 0x90]
	assert r.accept(0, &req[0], req.len, 1, 1, 1, 0) == .accepted
	mut f := can.Frame{
		id:  rsp_id
		len: 8
	}
	f.data[0] = 0x30 // flow control the link is not waiting for
	for t := u64(1_000_000); t < stall_us; t += 1_000_000 {
		r.pump(t, mut ch)
		r.on_frame(edge, &f, t)
		r.step(t)
	}
	r.step(stall_us)
	assert !r.busy() && r.timeouts == 1
}

fn test_the_answer_wait_starts_when_the_request_has_left() {
	mut r := new_router()
	mut ch := Chan{}
	req := [u8(0x22), 0xF1, 0x90]
	assert r.accept(0, &req[0], req.len, 1, 1, 1, 0) == .accepted
	r.pump(1000, mut ch) // the single frame leaves at 1 ms
	r.step(11_000) // the next pass, 10 ms later
	mut f := can.Frame{
		id:  rsp_id
		len: 8
	}
	f.data[0] = 0x03
	f.data[1] = 0x62
	f.data[2] = 0xF1
	f.data[3] = 0x90
	assert !r.on_frame(edge, &f, 1000 + answer_wait_us + 5000) // after the wait, counted from 1 ms
	assert r.timeouts == 1
}

// what a real server answers is what answers() takes: each request to a comm/uds server, its actual
// answer judged against the request (it answers it) and against another request of the same
// service (it does not, wherever the protocol can tell) — the one table every correlation rule
// is held to
fn served(mut srv uds.Server, req []u8) []u8 {
	mut resp := []u8{len: isotp.default_message}
	n := srv.handle(&req[0], req.len, unsafe { &resp[0] })
	return resp[..n].clone()
}

fn judged(a []u8, req []u8) bool {
	return answers(&a[0], a.len, &req[0], if req.len < req_head_len { req.len } else { req_head_len },
		req.len)
}

fn test_a_real_servers_answers_are_told_apart_by_the_correlation() {
	mut srv := uds.Server{}
	srv.init(isotp.default_message)
	srv.dids[0] = uds.Did{
		id: 0xF190
	}
	srv.dids[0].data[0] = `Z`
	srv.dids[0].len = 1
	srv.dids[1] = uds.Did{
		id:       0x0102
		writable: true
		len:      1
	}
	srv.ndid = 2
	srv.ios[0] = uds.IoControl{
		did:      0xF1A0
		width:    1
		hi:       200
		params:   0x0E
		sessions: 0xFF
	}
	srv.ios[1] = uds.IoControl{
		did:      0xF1A2
		width:    1
		hi:       200
		params:   0x0E
		sessions: 0xFF
	}
	srv.nio = 2
	cases := [
		// request, another request of the same service
		[[u8(0x10), 0x03], [u8(0x10), 0x01]],
		[[u8(0x3E), 0x00], []u8{}],
		[[u8(0x22), 0xF1, 0x90], [u8(0x22), 0x01, 0x02]],
		[[u8(0x22), 0xF1, 0xFF, 0xF1, 0x90], [u8(0x22), 0x01, 0x02]], // F1FF unserved: answered from F190
		[[u8(0x2E), 0x01, 0x02, 0x05], [u8(0x2E), 0xF1, 0x90, 0x05]],
		[[u8(0x2F), 0xF1, 0xA0, 0x03, 0x07], [u8(0x2F), 0xF1, 0xA2, 0x03, 0x07]], // another DID
		[[u8(0x2F), 0xF1, 0xA0, 0x02], [u8(0x2F), 0xF1, 0xA0, 0x00]], // another parameter
	]
	for c in cases {
		srv.session = 0x03 // the extended session the writes and resets ask for
		a := served(mut srv, c[0])
		assert a.len > 0, 'no answer to ${c[0]}'
		assert judged(a, c[0]), '${a} does not answer ${c[0]}'
		if c[1].len > 0 && a[0] != 0x7F {
			assert !judged(a, c[1]), '${a} taken as the answer to ${c[1]}'
		}
	}
	// a suppressed request still owes its answer after a responsePending: the bit is not echoed
	assert judged([u8(0x71), 0x01, 0xFF, 0x00], [u8(0x31), 0x81, 0xFF, 0x00])
	assert !judged([u8(0x71), 0x01, 0xFF, 0x01], [u8(0x31), 0x81, 0xFF, 0x00])
	// Authentication echoes its sub-function
	assert judged([u8(0x69), 0x01, 0x11], [u8(0x29), 0x01]) && !judged([u8(0x69), 0x02], [u8(0x29), 0x01])
	// a 0x22 with more DIDs than were kept: a later one cannot be told, so it is taken
	mut many := [u8(0x22)]
	for i in 0 .. 20 {
		many << u8(0xA0)
		many << u8(i)
	}
	assert judged([u8(0x62), 0xA0, 19, 0x00], many)
	assert !judged([u8(0x62), 0xB0, 0x00, 0x00], many[..7])
}

// N_Ar off (n_ar_us 0), so the stall bound is what ends the exchange and the frames it ignores are
// what must not hold it off
fn test_a_frame_iso_tp_ignores_is_no_progress() {
	mut r := new_router()
	r.link.n_ar_us = 0
	mut n := new_node()
	mut ch := Chan{}
	mut now := u64(0)
	req := [u8(0x22), 0xF1, 0x00]
	assert r.accept(0, &req[0], req.len, 1, 1, 1, now) == .accepted
	run(mut r, mut n, mut ch, mut &now, 2)
	mut long := [u8(0x62), 0xF1, 0x00]
	for i in 0 .. 40 {
		long << u8(i)
	}
	answer(mut n, long)
	ch.stalled = true // our flow control cannot leave
	run(mut r, mut n, mut ch, mut &now, 3)
	mut f := can.Frame{
		id:  rsp_id
		len: 8
	}
	f.data[0] = 0x40 // a reserved PCI, once a second
	for t := now + 1_000_000; t < now + stall_us; t += 1_000_000 {
		r.on_frame(edge, &f, t)
		r.step(t)
	}
	assert r.busy() // past N_Ar: only the stall bound ends it
	r.step(now + stall_us)
	assert !r.busy() && r.timeouts == 1
}

fn test_a_transfer_that_has_run_out_does_not_hold_the_next_request_off() {
	mut r := new_router()
	mut ch := Chan{}
	mut block := [u8(0x36), 0x01]
	for i in 0 .. 100 {
		block << u8(i)
	}
	assert r.accept(0, unsafe { &block[0] }, block.len, 1, 1, 1, 0) == .accepted
	r.pump(1000, mut ch) // the first frame; no flow control comes
	// the retry arrives at the N_Bs deadline, before the pass's step
	req := [u8(0x3E), 0x00]
	assert r.accept(0, &req[0], req.len, 1, 2, 1, 1_001_000) == .accepted
}

// the stall bound holds whatever frames keep arriving that move nothing — the class, not one shape.
// N_Ar is off (n_ar_us 0) throughout: with it, ISO-TP would end each of these at 1 s, whatever the
// frames did to the stall bound
fn test_no_frame_that_moves_nothing_keeps_a_stalled_exchange_alive() {
	junk := [
		[u8(0x40)], // reserved PCI
		[u8(0x30), 0x00, 0x00], // flow control the link is not waiting for
		[u8(0x10)], // a truncated first frame (rejected before the link)
		[u8(0x05), 0x62], // a truncated single frame
		[u8(0x2F), 1, 2, 3, 4, 5, 6, 7], // a consecutive frame out of sequence
		[u8(0x10), 43, 0x62, 0xF1, 0x00, 0, 1, 2], // the answer's first frame, repeated
	]
	for j in junk {
		mut r := new_router()
		r.link.n_ar_us = 0
		mut n := new_node()
		mut ch := Chan{}
		mut now := u64(0)
		req := [u8(0x22), 0xF1, 0x00]
		assert r.accept(0, &req[0], req.len, 1, 1, 1, now) == .accepted
		run(mut r, mut n, mut ch, mut &now, 2)
		mut long := [u8(0x62), 0xF1, 0x00]
		for i in 0 .. 40 {
			long << u8(i)
		}
		answer(mut n, long)
		ch.stalled = true // our flow control cannot leave: only the stall bound ends this
		run(mut r, mut n, mut ch, mut &now, 3)
		mut f := can.Frame{
			id:  rsp_id
			len: u8(j.len)
		}
		for i, b in j {
			f.data[i] = b
		}
		start := now
		for t := start + 1_000_000; t < start + stall_us; t += 1_000_000 {
			r.on_frame(edge, &f, t)
			r.step(t)
		}
		if j[0] != 0x2F { // an out-of-sequence consecutive frame ends the reception itself (REQ-CAN-TP-011)
			assert r.busy(), 'ended before the stall bound with ${j}'
		}
		r.step(start + stall_us)
		assert !r.busy(), 'kept alive by ${j}'
	}
	// a target that restarts its answer, first frame and the next, while our flow control cannot
	// leave, advances nothing either
	mut r := new_router()
	r.link.n_ar_us = 0
	mut n := new_node()
	mut ch := Chan{}
	mut now := u64(0)
	req := [u8(0x22), 0xF1, 0x00]
	assert r.accept(0, &req[0], req.len, 1, 1, 1, now) == .accepted
	run(mut r, mut n, mut ch, mut &now, 2)
	ch.stalled = true
	start := now
	for t := start + 100_000; t < start + stall_us; t += 100_000 {
		mut ff := can.Frame{
			id:  rsp_id
			len: 8
		}
		for i, b in [u8(0x10), 43, 0x62, 0xF1, 0x00, 0, 1, 2] {
			ff.data[i] = b
		}
		r.on_frame(edge, &ff, t)
		mut cf := can.Frame{
			id:  rsp_id
			len: 8
		}
		cf.data[0] = 0x21
		r.on_frame(edge, &cf, t + 50_000)
		r.step(t + 50_000)
	}
	assert r.busy() // past N_Ar: only the stall bound ends it
	r.step(start + 100_000 + stall_us) // the stall bound from the first first frame, the one that moved
	assert !r.busy()
}

// a target that answers our first frame with flow control WAITs, each within N_Bs and fewer than
// WFTmax, may keep the request waiting past the stall bound: ISO-TP bounds those waits, and the
// CTS that ends them sends the rest. The WAIT past WFTmax gives the request up (failed).
fn test_flow_control_waits_within_wftmax_keep_a_request_alive_past_the_stall_bound() {
	for waits in [7, 17] {
		mut r := new_router()
		mut ch := Chan{}
		req := []u8{len: 20, init: if index == 0 { u8(0x2E) } else { u8(index) }}
		assert r.accept(0, &req[0], req.len, 1, 1, 1, 0) == .accepted
		r.pump(0, mut ch)
		assert ch.tx.len == 1 && (ch.tx[0].data[0] & 0xF0) == 0x10 // the first frame
		ch.tx.clear()
		mut fc := can.Frame{
			id:  rsp_id
			len: 3
		}
		fc.data[0] = 0x31 // WAIT
		mut t := u64(0)
		for _ in 0 .. waits {
			t += 900_000 // within N_Bs (1 s)
			r.step(t)
			r.on_frame(edge, &fc, t)
		}
		if waits > 16 {
			r.step(t) // the step after it ends the exchange
			assert !r.busy() && r.failed == 1 && r.timeouts == 0 && r.active < 0
			continue
		}
		assert t > stall_us && r.busy() && r.timeouts == 0 && r.failed == 0
		fc.data[0] = 0x30 // CTS
		t += 900_000
		r.step(t)
		r.on_frame(edge, &fc, t)
		r.pump(t, mut ch)
		assert ch.tx.len == 2 // the two consecutive frames: the request left
		r.step(t)
		assert r.timeouts == 0 && r.failed == 0
	}
}

// the route is the connection's from the pass its tester holds the gateway's unlock, not from its
// first routed request: an unlock earned, then S3 waited out before routing, still routes — until
// the connection ends. Another level, or none, grants nothing.
fn test_an_unlock_held_before_the_first_route_outlasts_s3() {
	mut r := new_router()
	req := [u8(0x3E), 0x00]
	r.hold(0)
	r.hold(2)
	assert r.accept(0, &req[0], req.len, 4, 1, 0, 0) == .locked
	r.hold(1) // the pass the unlock was earned
	// S3 ran out before the first routed request: the server holds no unlock now
	assert r.accept(0, &req[0], req.len, 4, 2, 0, 6_000_000) == .accepted
	r.cancel() // the connection ended
	assert r.accept(0, &req[0], req.len, 5, 3, 0, 7_000_000) == .locked
}

// ReadDTCInformation 04 / 06 name one DTC, and the answer echoes it (comm/uds dtc_records: 59, the
// sub-function, the DTC, its status, then each stored record by number): a late answer for another
// DTC, or for another record of the same one, is not this request's — the tester's request that
// superseded it still gets its own
fn test_a_dtc_read_is_told_apart_by_its_dtc_and_record() {
	mut r := new_router()
	mut n := new_node()
	mut ch := Chan{}
	mut now := u64(0)
	req := [u8(0x19), 0x04, 0x44, 0x55, 0x66, 0x01]
	assert r.accept(0, &req[0], req.len, 1, 2, 1, now) == .accepted
	run(mut r, mut n, mut ch, mut &now, 2)
	answer(mut n, [u8(0x59), 0x04, 0x11, 0x22, 0x33, 0x09, 0x01, 0xAA]) // DTC 112233's, given up on
	run(mut r, mut n, mut ch, mut &now, 2)
	assert r.waiting() == 0 && r.stale == 1
	answer(mut n, [u8(0x59), 0x04, 0x44, 0x55, 0x66, 0x09, 0x01, 0xBB])
	run(mut r, mut n, mut ch, mut &now, 2)
	assert take(mut r) == [u8(0x59), 0x04, 0x44, 0x55, 0x66, 0x09, 0x01, 0xBB]
	dtc := [u8(0x19), 0x06, 0x44, 0x55, 0x66, 0x02]
	assert judged([u8(0x59), 0x06, 0x44, 0x55, 0x66, 0x09, 0x02, 0x10], dtc)
	assert !judged([u8(0x59), 0x06, 0x44, 0x55, 0x66, 0x09, 0x01, 0x10], dtc) // another record
	assert judged([u8(0x59), 0x06, 0x44, 0x55, 0x66, 0x09], dtc) // the record is not stored
	all := [u8(0x19), 0x06, 0x44, 0x55, 0x66, 0xFF]
	assert judged([u8(0x59), 0x06, 0x44, 0x55, 0x66, 0x09, 0x01, 0x10], all)
	assert !judged([u8(0x59), 0x06, 0x44, 0x55], dtc) // shorter than any answer to it
	// a sub-function that names no DTC still matches by the sub-function alone
	assert judged([u8(0x59), 0x02, 0xFF, 0x11, 0x22, 0x33, 0x09], [u8(0x19), 0x02, 0xFF])
}

// an answer's reception that N_Cr has ended is over before the next frame is looked at, whatever
// order the owner's pass runs in: a single frame after it, past the answer wait, is no one's
fn test_a_frame_after_n_cr_ended_the_answer_is_not_taken() {
	mut r := new_router()
	mut ch := Chan{}
	req := [u8(0x22), 0xF1, 0x90]
	assert r.accept(0, &req[0], req.len, 1, 1, 1, 0) == .accepted
	r.pump(0, mut ch) // the request left at 0: the answer must begin by answer_wait_us
	mut ff := can.Frame{
		id:  rsp_id
		len: 8
	}
	ff.data[0] = 0x10 // first frame of a 20-byte answer, just in time
	ff.data[1] = 20
	ff.data[2] = 0x62
	t := answer_wait_us - 900_000
	r.on_frame(edge, &ff, t)
	r.pump(t, mut ch) // our flow control: N_Cr runs from here
	assert ch.tx.len == 2 && ch.tx[1].data[0] == 0x30
	mut sf := can.Frame{
		id:  rsp_id
		len: 8
	}
	sf.data[0] = 0x04
	sf.data[1] = 0x62
	sf.data[2] = 0xF1
	sf.data[3] = 0x90
	sf.data[4] = 0x5A
	late := t + 1_000_000 + 1_000 // past N_Cr, and past the answer wait: no step in between
	assert !r.on_frame(edge, &sf, late)
	assert r.waiting() == 0 && r.timeouts == 1 && !r.busy()
}

// ReadDTCInformation 06's 0xFE asks for every legislated OBD record (0x90..0xEF), any of which
// may come back first; 04 has no such selector
fn test_the_obd_record_selector_takes_any_obd_record() {
	obd := [u8(0x19), 0x06, 0x12, 0x34, 0x56, 0xFE]
	assert judged([u8(0x59), 0x06, 0x12, 0x34, 0x56, 0x09, 0x90, 0x01], obd)
	assert judged([u8(0x59), 0x06, 0x12, 0x34, 0x56, 0x09, 0xEF, 0x01], obd)
	assert !judged([u8(0x59), 0x06, 0x12, 0x34, 0x56, 0x09, 0x01, 0x01], obd)
	assert !judged([u8(0x59), 0x04, 0x12, 0x34, 0x56, 0x09, 0x90, 0x01], [u8(0x19), 0x04, 0x12,
		0x34, 0x56, 0xFE])
}

// the owner asks room() only while the exchange is on its bus, so the queue may empty without it
// asking: a queue that fills again is held anew, not counted from the hold that ran out before
fn test_a_queue_that_fills_again_is_held_anew() {
	mut r := new_router()
	req := [u8(0x31), 0x01, 0xFF, 0x00]
	assert r.accept(0, &req[0], req.len, 1, 1, 1, 0) == .accepted
	mut ch := Chan{}
	r.pump(100, mut ch)
	mut f := can.Frame{
		id:  rsp_id
		len: 8
	}
	f.data[0] = 0x03
	f.data[1] = 0x7F
	f.data[2] = 0x31
	f.data[3] = 0x78 // responsePending: the exchange stays open
	for _ in 0 .. queue_len {
		assert r.on_frame(edge, &f, 1000)
	}
	assert !r.room(1000)
	assert r.room(1000 + gate_hold_us) // the hold ran out
	r.pop()
	r.pop() // taken, with no room() asked in between
	t := 1000 + 10 * gate_hold_us
	for _ in 0 .. queue_len {
		assert r.on_frame(edge, &f, t)
	}
	assert !r.room(t), 'a queue full again is held anew'
	assert r.room(t + gate_hold_us)
}

// @verifies REQ-CAN-TP-023
// the router carries a routed request and its answer up to the gateway's own maximum message: at
// 4095 a request and an answer of that length go whole, one byte more is refused before anything
// of the exchange is touched, and the storage is the owner's
fn test_a_router_carries_messages_up_to_the_gateways_maximum() {
	m := isotp.message_limit
	assert storage_len(m) == 4 * m
	mut r := router_at(m)
	mut n := new_node()
	mut ch := Chan{}
	mut now := u64(0)
	big := []u8{len: m + 1, init: 0x2E}
	assert r.accept(0, &big[0], big.len, 1, 1, 1, now) == .too_large
	mut req := []u8{len: m, init: u8(index)}
	req[0] = 0x2E
	assert r.accept(0, unsafe { &req[0] }, req.len, 1, 2, 1, now) == .accepted
	for _ in 0 .. 2000 {
		now += 1000
		pass(mut r, mut n, mut ch, now)
		if n.requests.len > 0 {
			break
		}
	}
	assert n.requests.len == 1 && n.requests[0] == req
	mut ans := []u8{len: m, init: u8(index * 3)}
	ans[0] = 0x6E
	ans[1] = req[1]
	ans[2] = req[2]
	answer(mut n, ans)
	for _ in 0 .. 2000 {
		now += 1000
		pass(mut r, mut n, mut ch, now)
		if r.waiting() > 0 {
			break
		}
	}
	assert take(mut r) == ans
}

// an unbound router's link carries nothing: a request is refused
fn test_an_unbound_router_refuses() {
	mut r := Router{}
	assert r.add(Route{
		logical: la
		bus:     edge
		tx_id:   req_id
		rx_id:   rsp_id
	})
	r.active = -1
	r.level = 1
	req := [u8(0x3E), 0x00]
	assert r.accept(0, &req[0], req.len, 1, 1, 1, u64(0)) == .refused
}

// @verifies REQ-CAN-TP-025
// a routed node's answer longer than the gateway's maximum is refused on the bus (FC.OVFLW: the
// node gives it up at once) and the tester is answered responseTooLong in the node's name, for
// this request, at once rather than after its P2*; the exchange is over and the next one routes
fn test_an_answer_longer_than_the_gateways_maximum_is_answered_response_too_long() {
	mut r := new_router() // the gateway at the default 520
	mut n := new_node() // the node at 4095
	mut ch := Chan{}
	mut now := u64(0)
	req := [u8(0x22), 0xF1, 0x90, 0xF1, 0x90]
	assert r.accept(0, &req[0], req.len, 1, 9, 1, now) == .accepted
	run(mut r, mut n, mut ch, mut &now, 2)
	assert n.requests.len == 1
	mut long := []u8{len: isotp.default_message + 21, init: u8(index)}
	long[0] = 0x62
	long[1] = 0xF1
	long[2] = 0x90
	answer(mut n, long)
	run(mut r, mut n, mut ch, mut &now, 4)
	assert n.link.tx_aborts == 1, 'the node was refused by FC.OVFLW, not left to wait out N_Bs'
	assert r.waiting() == 1
	a := r.head()
	assert a.logical == la && a.ticket == 9
	assert take(mut r) == [u8(0x7F), 0x22, 0x14]
	assert r.too_long == 1 && r.timeouts == 0
	assert r.active_bus() == -1 && !r.busy(), 'the exchange ended with the refusal'
	ok := [u8(0x3E), 0x00]
	assert r.accept(0, &ok[0], ok.len, 1, 10, 1, now) == .accepted
	run(mut r, mut n, mut ch, mut &now, 2)
	answer(mut n, [u8(0x7E), 0x00])
	run(mut r, mut n, mut ch, mut &now, 2)
	assert take(mut r) == [u8(0x7E), 0x00]
}

// @verifies REQ-CAN-TP-023
// a gateway larger than the node behind it carries a request only up to the node's maximum
// (Route.max_message): a longer one is refused at once (too_large, DoIP's diagnostic NACK 0x04)
// rather than forwarded for the node to refuse with FC.OVFLW and the tester left to wait out its
// P2*; the exchange in flight is left alone, and a request of the node's length goes through. A
// route without a maximum, or one past the gateway's, carries up to the gateway's.
fn test_a_request_longer_than_the_routed_node_takes_is_refused_at_once() {
	mut r := router_at(isotp.message_limit)
	r.routes[0].max_message = isotp.default_message
	assert r.route_max(0) == isotp.default_message
	mut n := new_node()
	n.link.bind_rx(n.link.rx_buf, isotp.default_message) // the node at 520
	mut ch := Chan{}
	mut now := u64(0)
	tp := [u8(0x3E), 0x00]
	assert r.accept(0, &tp[0], tp.len, 1, 1, 1, now) == .accepted
	run(mut r, mut n, mut ch, mut &now, 2)
	mut big := []u8{len: isotp.default_message + 1, init: u8(index)}
	big[0] = 0x2E
	assert r.accept(0, unsafe { &big[0] }, big.len, 1, 2, 1, now) == .too_large
	assert r.forwarded == 1 && r.active_bus() == int(edge), 'the exchange in flight is untouched'
	run(mut r, mut n, mut ch, mut &now, 2)
	assert n.requests.len == 1 && n.link.tx_aborts == 0 && r.failed == 0, 'nothing of it reached the node'
	answer(mut n, [u8(0x7E), 0x00])
	run(mut r, mut n, mut ch, mut &now, 2)
	assert take(mut r) == [u8(0x7E), 0x00]
	fits := big[..isotp.default_message].clone()
	assert r.accept(0, unsafe { &fits[0] }, fits.len, 1, 3, 1, now) == .accepted
	run(mut r, mut n, mut ch, mut &now, 120)
	assert n.requests.last() == fits
	// no maximum, or one past the gateway's: the gateway's
	r.routes[0].max_message = 0
	assert r.route_max(0) == isotp.message_limit
	mut g := new_router()
	g.routes[0].max_message = isotp.message_limit
	assert g.route_max(0) == isotp.default_message
}

// @verifies REQ-CAN-TP-025
// a too-long answer is the request in flight's only when it answers it, like any answer: a late
// one to an earlier request (its first frame names another service) is refused on the bus with
// FC.OVFLW as ever, counted stale and not answered responseTooLong — the exchange in flight goes
// on and its own answer still comes
fn test_a_late_too_long_answer_to_an_earlier_request_is_not_this_ones() {
	mut r := new_router() // the gateway at 520
	mut n := new_node() // the node at 4095
	mut ch := Chan{}
	mut now := u64(0)
	tp := [u8(0x3E), 0x00]
	assert r.accept(0, &tp[0], tp.len, 1, 4, 1, now) == .accepted
	run(mut r, mut n, mut ch, mut &now, 2)
	mut late := []u8{len: isotp.default_message + 21, init: u8(index)}
	late[0] = 0x62 // the answer to a 0x22 the tester gave up on
	late[1] = 0xF1
	late[2] = 0x90
	answer(mut n, late)
	run(mut r, mut n, mut ch, mut &now, 4)
	assert n.link.tx_aborts == 1, 'refused on the bus all the same'
	assert r.too_long == 0 && r.stale == 1 && r.waiting() == 0
	assert r.active_bus() == int(edge), 'the exchange in flight goes on'
	answer(mut n, [u8(0x7E), 0x00])
	run(mut r, mut n, mut ch, mut &now, 2)
	assert take(mut r) == [u8(0x7E), 0x00]
	// first_frame_answers reads the bytes a first frame carries, after an escape length too
	req := [u8(0x22), 0xF1, 0x90]
	mut ff := can.Frame{
		id:  rsp_id
		len: 8
	}
	for i, b in [u8(0x12), 0x15, 0x62, 0xF1, 0x90, 0, 0, 0] {
		ff.data[i] = b
	}
	assert first_frame_answers(&ff, &req[0], req.len, req.len)
	ff.data[2] = 0x6E
	assert !first_frame_answers(&ff, &req[0], req.len, req.len)
	for i, b in [u8(0x10), 0x00, 0x00, 0x00, 0x10, 0x00, 0x7F, 0x22] {
		ff.data[i] = b
	}
	assert first_frame_answers(&ff, &req[0], req.len, req.len)
	ff.data[7] = 0x2E
	assert !first_frame_answers(&ff, &req[0], req.len, req.len)
}

// @verifies REQ-CAN-TP-025
// a node whose bootloader offers TransferData blocks longer than the gateway carries has its
// RequestDownload answer lowered to the gateway's maximum (whatever the width of the length), and
// a block of that length then goes through to it; an offer the gateway carries is left alone
fn test_a_request_download_answer_is_lowered_to_the_gateways_maximum() {
	mut r := new_router()
	mut n := new_node()
	mut ch := Chan{}
	mut now := u64(0)
	rd := [u8(0x34), 0x00, 0x44, 0x08, 0x02, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00]
	assert r.accept(0, &rd[0], rd.len, 1, 1, 1, now) == .accepted
	run(mut r, mut n, mut ch, mut &now, 4)
	answer(mut n, [u8(0x74), 0x20, 0x0F, 0xE2]) // 4066: a bootloader at 4095
	run(mut r, mut n, mut ch, mut &now, 2)
	assert take(mut r) == [u8(0x74), 0x20, 0x02, 0x08] // 520
	assert r.lowered == 1
	mut block := []u8{len: isotp.default_message, init: u8(index)}
	block[0] = 0x36
	block[1] = 0x01
	assert r.accept(0, unsafe { &block[0] }, block.len, 1, 2, 1, now) == .accepted
	run(mut r, mut n, mut ch, mut &now, 120)
	assert n.requests.last() == block
	// the offers fit_block_length leaves alone, and the widths it lowers in
	mut fits := [u8(0x74), 0x20, 0x02, 0x02] // 514: carried
	assert !fit_block_length(unsafe { &fits[0] }, fits.len, 520) && fits == [u8(0x74), 0x20, 0x02, 0x02]
	mut wide := [u8(0x74), 0x40, 0x00, 0x00, 0x10, 0x00]
	assert fit_block_length(unsafe { &wide[0] }, wide.len, 520) && wide == [u8(0x74), 0x40, 0x00, 0x00, 0x02, 0x08]
	mut narrow := [u8(0x74), 0x10, 0xFF]
	assert fit_block_length(unsafe { &narrow[0] }, narrow.len, 64) && narrow == [u8(0x74), 0x10, 0x40]
	// a field wider than four bytes, as ISO 14229-1 allows (1..15): lowered in its own width, its
	// leading bytes zero — past eight bytes too, where a nonzero leading byte is more than any
	// gateway carries
	mut five := [u8(0x74), 0x50, 0x00, 0x00, 0x00, 0x0F, 0xE2] // 4066
	assert fit_block_length(unsafe { &five[0] }, five.len, 520)
	assert five == [u8(0x74), 0x50, 0x00, 0x00, 0x00, 0x02, 0x08]
	mut ten := [u8(0x74), 0xA0, 0x01, 0, 0, 0, 0, 0, 0, 0, 0x00, 0x10]
	assert fit_block_length(unsafe { &ten[0] }, ten.len, 520)
	assert ten == [u8(0x74), 0xA0, 0, 0, 0, 0, 0, 0, 0, 0, 0x02, 0x08]
	mut ten_fits := [u8(0x74), 0xA0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01, 0x00]
	assert !fit_block_length(unsafe { &ten_fits[0] }, ten_fits.len, 520)
	for bad in [[u8(0x74), 0x00, 0xFF], [u8(0x74), 0x50, 0, 0, 0, 0x0F], [u8(0x74), 0x20, 0xFF],
		[u8(0x7F), 0x34, 0x22]] {
		mut b := bad.clone()
		assert !fit_block_length(unsafe { &b[0] }, b.len, 8) && b == bad, bad.str()
	}
}

// @verifies REQ-CAN-TP-023
// a routed answer the router never takes is never framed past the gateway's limit either: the
// router's link holds no more than the gateway's maximum, so an answer one byte longer is not
// queued as one
fn test_the_routers_link_takes_no_answer_past_the_gateways_maximum() {
	mut r := router_at(64)
	mut n := new_node()
	mut ch := Chan{}
	mut now := u64(0)
	req := [u8(0x22), 0xF1, 0x90]
	assert r.accept(0, &req[0], req.len, 1, 1, 1, now) == .accepted
	run(mut r, mut n, mut ch, mut &now, 2)
	mut exact := []u8{len: 64, init: u8(index)}
	exact[0] = 0x62
	exact[1] = 0xF1
	exact[2] = 0x90
	answer(mut n, exact)
	run(mut r, mut n, mut ch, mut &now, 20)
	assert take(mut r) == exact
	assert r.accept(0, &req[0], req.len, 1, 2, 1, now) == .accepted
	run(mut r, mut n, mut ch, mut &now, 2)
	mut over := exact.clone()
	over << 0xEE
	answer(mut n, over)
	run(mut r, mut n, mut ch, mut &now, 20)
	assert take(mut r) == [u8(0x7F), 0x22, 0x14], 'not the 65-byte answer'
}

// @verifies REQ-CAN-TP-025
// a first frame shorter than its PCI says is nothing to the router, as it is to the link
// (isotp on_frame): five bytes announcing an answer past a gateway of 8 neither answer the
// request in flight responseTooLong nor end its exchange — its own answer still comes
fn test_a_truncated_oversize_first_frame_is_not_answered_response_too_long() {
	mut r := router_at(8)
	mut n := new_node()
	mut ch := Chan{}
	mut now := u64(0)
	req := [u8(0x22), 0xF1, 0x90]
	assert r.accept(0, &req[0], req.len, 1, 1, 1, now) == .accepted
	run(mut r, mut n, mut ch, mut &now, 2)
	mut short := can.Frame{
		id:  rsp_id
		len: 5
	}
	for i, b in [u8(0x10), 0x20, 0x62, 0xF1, 0x90] {
		short.data[i] = b
	}
	assert r.on_frame(edge, &short, now)
	assert r.waiting() == 0 && r.too_long == 0
	assert r.active_bus() == int(edge), 'the exchange in flight goes on'
	run(mut r, mut n, mut ch, mut &now, 2)
	answer(mut n, [u8(0x62), 0xF1, 0x90, 0x41])
	run(mut r, mut n, mut ch, mut &now, 2)
	assert take(mut r) == [u8(0x62), 0xF1, 0x90, 0x41]
	assert !oversize_first_frame(&r.link, &short)
	short.len = 8
	assert oversize_first_frame(&r.link, &short), 'the whole frame is one the link refuses'
}

// @verifies REQ-CAN-TP-025
// a too-long final answer five seconds after a responsePending — inside the answer wait, past the
// stall window that wait ran down — is still refused on the bus: its FC.OVFLW reaches the node
// (which gives the answer up at once) and the tester gets the responseTooLong, the exchange not
// counted as stalled
fn test_a_too_long_answer_late_in_the_answer_wait_still_refuses_the_target() {
	mut r := new_router() // the gateway at 520
	mut n := new_node() // the node at 4095
	mut ch := Chan{}
	mut now := u64(0)
	req := [u8(0x22), 0xF1, 0x90]
	assert r.accept(0, &req[0], req.len, 1, 7, 1, now) == .accepted
	run(mut r, mut n, mut ch, mut &now, 2)
	answer(mut n, [u8(0x7F), 0x22, 0x78])
	run(mut r, mut n, mut ch, mut &now, 2)
	assert take(mut r) == [u8(0x7F), 0x22, 0x78]
	now += 5_000_000
	mut long := []u8{len: isotp.default_message + 21, init: u8(index)}
	long[0] = 0x62
	long[1] = 0xF1
	long[2] = 0x90
	answer(mut n, long)
	run(mut r, mut n, mut ch, mut &now, 4)
	assert n.link.tx_aborts == 1, 'the node was refused by FC.OVFLW'
	assert take(mut r) == [u8(0x7F), 0x22, 0x14]
	assert r.timeouts == 0 && r.too_long == 1 && !r.busy()
}

// ---- CAN-FD frames on a route, and N_Ar ---------------------------------------------------------

// @verifies REQ-CAN-TP-026 REQ-CAN-TP-027
// a route sends at its node's TX_DL: at 64 a 100-byte request is a first frame of 64 bytes and a
// consecutive frame of the last 38, padded to 48; a route at 0 sends 8-byte frames, also right after
// one at 64 (the link takes the value per request); the flow control it answers an answer with is 8
fn test_a_route_sends_at_its_nodes_tx_dl() {
	mut r := new_router()
	r.routes[0].tx_dl = 64
	assert r.add(Route{
		logical: 0x07D0
		bus:     edge
		tx_id:   0x7D0
		rx_id:   0x7D8
	})
	mut n := new_node()
	mut ch := Chan{}
	mut req := []u8{len: 100, init: u8(index)}
	req[0] = 0x2E
	assert r.accept(0, unsafe { &req[0] }, req.len, 1, 1, 1, 0) == .accepted
	r.pump(0, mut ch)
	assert ch.tx.len == 1 && ch.tx[0].len == 64
	assert ch.tx[0].data[..2] == [u8(0x10), 100] && ch.tx[0].data[2..64] == req[..62]
	n.link.on_frame(0, pdu(ch.tx[0]))
	ch.tx.clear()
	mut fc := isotp.Pdu{}
	assert n.link.poll(0, mut fc) && fc.len == 8
	f := frame(rsp_id, fc)
	r.on_frame(edge, &f, 0)
	r.pump(1000, mut ch)
	assert ch.tx.len == 1 && ch.tx[0].len == 48
	assert ch.tx[0].data[0] == 0x21 && ch.tx[0].data[1..39] == req[62..]
	for i in 39 .. 48 {
		assert ch.tx[0].data[i] == 0
	}
	n.link.on_frame(1000, pdu(ch.tx[0]))
	ch.tx.clear()
	assert n.link.has_request()
	// the next request, to the route at 0: 8-byte frames again
	long := []u8{len: 20, init: 0x2E}
	assert r.accept(1, &long[0], long.len, 1, 2, 1, 2000) == .accepted
	r.pump(2000, mut ch)
	assert ch.tx.len == 1 && ch.tx[0].len == 8 && ch.tx[0].id == 0x7D0
}

// @verifies REQ-CAN-TP-028
// the router takes its node's answer in 64-byte frames with no setting of its own, and a first frame
// it refuses is matched to the request by bytes past the eighth
fn test_the_router_takes_an_answer_in_64_byte_frames() {
	mut r := new_router()
	mut n := new_node()
	n.link.tx_dl = 64
	mut ch := Chan{}
	mut now := u64(0)
	req := [u8(0x22), 0xF1, 0x90]
	assert r.accept(0, &req[0], req.len, 1, 1, 1, now) == .accepted
	run(mut r, mut n, mut ch, mut &now, 2)
	mut ans := []u8{len: 300, init: u8(index)}
	ans[0] = 0x62
	ans[1] = 0xF1
	ans[2] = 0x90
	answer(mut n, ans)
	run(mut r, mut n, mut ch, mut &now, 6)
	assert take(mut r) == ans
	// an escape first frame of 64 bytes (refused) answers the request by what it carries
	mut ff := can.Frame{
		id:  rsp_id
		len: 64
	}
	for i, b in [u8(0x10), 0x00, 0x00, 0x00, 0x10, 0x00, 0x62, 0xF1, 0x90] {
		ff.data[i] = b
	}
	many := [u8(0x22), 0xF1, 0x80, 0xF1, 0x90] // the answer's DID is the request's second
	assert first_frame_answers(&ff, &many[0], many.len, many.len)
	ff.data[8] = 0x91
	assert !first_frame_answers(&ff, &many[0], many.len, many.len)
}

// @verifies REQ-CAN-TP-025 REQ-CAN-TP-028
// a 64-byte first frame announcing more than the gateway carries is refused and answered
// responseTooLong as an 8-byte one is; a 10-byte one — no CAN-FD length, a frame the link ignores —
// is nothing: no responseTooLong, no FC.OVFLW owed, the exchange still waiting for its answer
fn test_an_oversize_fd_first_frame_and_a_frame_of_no_fd_length() {
	mut r := new_router()
	mut n := new_node()
	mut ch := Chan{}
	mut now := u64(0)
	req := [u8(0x22), 0xF1, 0x90]
	assert r.accept(0, &req[0], req.len, 1, 1, 1, now) == .accepted
	run(mut r, mut n, mut ch, mut &now, 2)
	mut odd := can.Frame{
		id:  rsp_id
		len: 10
	}
	for i, b in [u8(0x13), 0x00, 0x62, 0xF1, 0x90, 0, 0, 0, 0, 0] {
		odd.data[i] = b
	}
	assert !oversize_first_frame(&r.link, &odd)
	assert r.on_frame(edge, &odd, now)
	assert r.waiting() == 0 && r.too_long == 0 && r.link.idle()
	assert r.active_bus() == int(edge), 'the exchange in flight goes on'
	mut ff := odd
	ff.len = 64
	assert oversize_first_frame(&r.link, &ff)
	assert r.on_frame(edge, &ff, now)
	assert take(mut r) == [u8(0x7F), 0x22, 0x14]
	assert r.too_long == 1
	r.pump(now, mut ch)
	assert ch.tx.len == 1 && ch.tx[0].len == 8 && ch.tx[0].data[0] == 0x32
}

// @verifies REQ-CAN-TP-029
// our flow control for an answer that cannot leave (the gateway's controller takes nothing) is
// given up by ISO-TP after N_Ar, and the exchange ends then, counted — not at the stall bound; the
// abandoned answer is not held against the next exchange, which is routed and answered
fn test_an_answer_whose_flow_control_cannot_leave_ends_at_n_ar() {
	mut r := new_router()
	mut n := new_node()
	mut ch := Chan{}
	mut now := u64(0)
	req := [u8(0x22), 0xF1, 0x00]
	assert r.accept(0, &req[0], req.len, 1, 1, 1, now) == .accepted
	run(mut r, mut n, mut ch, mut &now, 2)
	mut long := [u8(0x62), 0xF1, 0x00]
	for i in 0 .. 40 {
		long << u8(i)
	}
	answer(mut n, long)
	ch.stalled = true
	run(mut r, mut n, mut ch, mut &now, 1) // the answer's first frame: our CTS is owed from here
	owed := now
	r.step(owed + 999_999)
	assert r.busy() && r.timeouts == 0
	r.step(owed + 1_000_000)
	assert !r.busy() && r.timeouts == 1 && r.active_bus() == -1
	// the bus drains again; the node, its own send given up (N_Bs), takes the next request
	ch.stalled = false
	n = new_node()
	now = owed + 1_000_000
	assert r.accept(0, &req[0], req.len, 1, 1, 1, now) == .accepted
	run(mut r, mut n, mut ch, mut &now, 2)
	assert n.requests == [req]
	answer(mut n, long)
	run(mut r, mut n, mut ch, mut &now, 8)
	assert r.timeouts == 1
	assert take(mut r) == long
	assert !r.busy()
}

// ---- a node on 29-bit ids (its [[doip.route]] ext, REQ-NET-021) ----

// the node at address 0x20 on normal fixed addressing, the tester address 0xF1
const req29 = u32(0x18DA20F1)
const rsp29 = u32(0x18DAF120)

fn router29() Router {
	mut r := Router{}
	storage := []u8{len: storage_len(isotp.default_message)}
	r.init(1, 8, &storage[0], isotp.default_message)
	assert r.add(Route{
		logical: la
		bus:     edge
		tx_id:   req29
		rx_id:   rsp29
		ext:     true
	})
	return r
}

// pass29: pass() on the 29-bit route — every frame the router sends is 29-bit on the request id,
// and the node's frames come back 29-bit on its response id
fn pass29(mut r Router, mut n Node, mut ch Chan, now u64) {
	r.step(now)
	r.pump(now, mut ch)
	for f in ch.tx {
		assert f.id == req29 && f.ext
		n.link.on_frame(now, pdu(f))
	}
	ch.tx.clear()
	if n.link.has_request() {
		mut buf := []u8{len: isotp.message_limit}
		got := n.link.take(unsafe { &buf[0] })
		n.requests << buf[..got]
	}
	mut p := isotp.Pdu{}
	for n.link.poll(now, mut p) {
		mut f := frame(rsp29, p)
		f.ext = true
		r.on_frame(edge, &f, now)
	}
}

fn test_a_29_bit_route_sends_and_takes_29_bit_frames() {
	mut r := router29()
	mut n := new_node()
	mut ch := Chan{}
	mut now := u64(0)
	// a multi-frame request: its first frame goes out, and the rest on the node's 29-bit flow control
	mut req := [u8(0x2E), 0xF1, 0x90]
	for i in 0 .. 20 {
		req << u8(i)
	}
	assert r.accept(0, unsafe { &req[0] }, req.len, 1, 1, 1, now) == .accepted
	for _ in 0 .. 6 {
		now += 1000
		pass29(mut r, mut n, mut ch, now)
	}
	assert n.requests == [req]
	answer(mut n, [u8(0x6E), 0xF1, 0x90])
	for _ in 0 .. 3 {
		now += 1000
		pass29(mut r, mut n, mut ch, now)
	}
	assert take(mut r) == [u8(0x6E), 0xF1, 0x90]
	// a multi-frame answer, under our 29-bit flow control
	read := [u8(0x22), 0xF1, 0x90]
	assert r.accept(0, &read[0], read.len, 1, 2, 1, now) == .accepted
	for _ in 0 .. 3 {
		now += 1000
		pass29(mut r, mut n, mut ch, now)
	}
	assert n.requests.last() == read
	mut ans := [u8(0x62), 0xF1, 0x90]
	for i in 0 .. 30 {
		ans << u8(0x80 + i)
	}
	answer(mut n, ans)
	for _ in 0 .. 6 {
		now += 1000
		pass29(mut r, mut n, mut ch, now)
	}
	assert take(mut r) == ans
}

fn test_a_29_bit_route_ignores_its_numbers_as_11_bit_frames() {
	mut r := router29()
	req := [u8(0x3E), 0x00]
	assert r.accept(0, &req[0], req.len, 1, 1, 1, u64(0)) == .accepted
	mut ch := Chan{}
	r.pump(500, mut ch) // the request out: what comes now is its answer
	assert ch.tx.len == 1 && ch.tx[0].ext && ch.tx[0].id == req29
	mut f := can.Frame{
		id:  rsp29
		len: 8
	}
	f.data[0] = 0x02
	f.data[1] = 0x7E
	assert !r.on_frame(edge, &f, 1000) // the response number as an 11-bit frame
	f.ext = true
	assert r.on_frame(edge, &f, 1000)
	assert r.waiting() == 1
}

// @verifies REQ-CAN-TP-026 REQ-NET-021
// a 29-bit route at its node's TX_DL 64: the request goes out in 29-bit frames of up to 64 bytes
// (a first frame of 64, the rest in one consecutive frame) and reaches the node whole
fn test_a_29_bit_route_sends_at_its_nodes_tx_dl() {
	mut r := router29()
	r.routes[0].tx_dl = 64
	mut n := new_node()
	mut ch := Chan{}
	mut now := u64(0)
	mut req := []u8{len: 100, init: u8(index)}
	req[0] = 0x2E
	assert r.accept(0, unsafe { &req[0] }, req.len, 1, 1, 1, now) == .accepted
	r.pump(now, mut ch)
	assert ch.tx.len == 1 && ch.tx[0].ext && ch.tx[0].id == req29 && ch.tx[0].len == 64
	n.link.on_frame(now, pdu(ch.tx[0]))
	ch.tx.clear()
	for _ in 0 .. 4 {
		now += 1000
		pass29(mut r, mut n, mut ch, now)
	}
	assert n.requests == [req]
}
