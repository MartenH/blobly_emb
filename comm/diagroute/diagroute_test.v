module diagroute

// The router between a DoIP tester and a node behind the gateway, against a scripted node on its
// own ISO-TP link: what is forwarded, what comes back and in which order, how long the gateway
// waits, and who may route at all.
// @verifies REQ-NET-019 REQ-NET-020
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
	return n
}

fn new_router() Router {
	mut r := Router{}
	r.init(1, 8)
	assert r.add(Route{
		logical: la
		bus:     edge
		tx_id:   req_id
		rx_id:   rsp_id
	})
	return r
}

fn frame(id u32, p isotp.Pdu) can.Frame {
	mut f := can.Frame{
		id:  id
		len: 8
	}
	for i in 0 .. 8 {
		f.data[i] = p.data[i]
	}
	return f
}

fn pdu(f can.Frame) isotp.Pdu {
	mut p := isotp.Pdu{}
	for i in 0 .. 8 {
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
		mut buf := []u8{len: isotp.max_payload}
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
	out := a.data[..a.len].clone()
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

fn test_an_unanswered_exchange_ends_after_the_answer_wait() {
	mut r := new_router()
	mut n := new_node()
	mut ch := Chan{}
	mut now := u64(0)
	req := [u8(0x22), 0xF1, 0x95]
	assert r.accept(0, &req[0], req.len, 1, 1, 1, now) == .accepted
	run(mut r, mut n, mut ch, mut &now, 2)
	now += answer_wait_us
	run(mut r, mut n, mut ch, mut &now, 1)
	assert r.timeouts == 1
	assert !r.busy()
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
	assert !r.on_frame(edge, &f, 1000) // an extended id
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
	req := []u8{len: isotp.max_payload + 1}
	assert r.accept(0, &req[0], 0, 1, 1, 1, u64(0)) == .refused
	assert r.accept(0, &req[0], req.len, 1, 1, 1, u64(0)) == .refused
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
	assert r.accept(0, unsafe { &block[0] }, block.len, 1, 1, 1, now) == .accepted
	// 74 consecutive frames 127 ms apart: about 9.4 s, longer than stall_us
	for _ in 0 .. 400 {
		now += 30_000
		pass(mut r, mut n, mut ch, now)
		if n.requests.len > 0 {
			break
		}
	}
	assert n.requests.len == 1 && n.requests[0] == block
	assert now > stall_us
	assert r.timeouts == 0 && r.failed == 0
}

fn test_flow_control_that_cannot_leave_ends_the_exchange() {
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
	ch.stalled = true // the gateway's controller takes nothing: our flow control never leaves
	run(mut r, mut n, mut ch, mut &now, 3)
	assert r.busy()
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
	mut f := can.Frame{
		id:  rsp_id
		len: 8
	}
	f.data[0] = 0x02
	f.data[1] = 0x76
	assert !r.on_frame(edge, &f, 2_000_100)
	assert r.waiting() == 0
}

fn test_an_invalid_request_leaves_the_exchange_in_flight_alone() {
	mut r := new_router()
	mut ch := Chan{}
	req := [u8(0x31), 0x01, 0xFF, 0x00]
	assert r.accept(0, &req[0], req.len, 1, 1, 1, 0) == .accepted
	r.pump(500, mut ch)
	r.step(600)
	big := []u8{len: isotp.max_payload + 1}
	assert r.accept(0, &big[0], big.len, 1, 2, 1, 700) == .refused
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
	r.cancel()
	assert r.waiting() == 0 && !r.busy() && r.active_bus() == -1
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
		stalled: true // the request's first frame cannot leave
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
	mut resp := []u8{len: isotp.max_payload}
	n := srv.handle(&req[0], req.len, unsafe { &resp[0] })
	return resp[..n].clone()
}

fn judged(a []u8, req []u8) bool {
	return answers(&a[0], a.len, &req[0], if req.len < req_head_len { req.len } else { req_head_len },
		req.len)
}

fn test_a_real_servers_answers_are_told_apart_by_the_correlation() {
	mut srv := uds.Server{}
	srv.init(isotp.max_payload)
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
	cases := [
		// request, another request of the same service
		[[u8(0x10), 0x03], [u8(0x10), 0x01]],
		[[u8(0x3E), 0x00], []u8{}],
		[[u8(0x22), 0xF1, 0x90], [u8(0x22), 0x01, 0x02]],
		[[u8(0x22), 0xF1, 0xFF, 0xF1, 0x90], [u8(0x22), 0x01, 0x02]], // F1FF unserved: answered from F190
		[[u8(0x2E), 0x01, 0x02, 0x05], [u8(0x2E), 0xF1, 0x90, 0x05]],
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

fn test_a_frame_iso_tp_ignores_is_no_progress() {
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

// the stall bound holds whatever frames keep arriving that move nothing — the class, not one shape
fn test_no_frame_that_moves_nothing_keeps_a_stalled_exchange_alive() {
	junk := [
		[u8(0x40)], // reserved PCI
		[u8(0x30), 0x00, 0x00], // flow control the link is not waiting for
		[u8(0x10)], // a truncated first frame (rejected before the link)
		[u8(0x05), 0x62], // a truncated single frame
		[u8(0x2F), 1, 2, 3, 4, 5, 6, 7], // a consecutive frame out of sequence
	]
	for j in junk {
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
		r.step(start + stall_us)
		assert !r.busy(), 'kept alive by ${j}'
	}
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
