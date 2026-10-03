module diag

// The shared transport step (step.v) — once, for every owner: the application's Connection calls its
// pieces, the bootloader runs serve_step whole. Each case is a defect a hand-written serve loop had
// (codex #367 r4-r5): a truncated frame read as a request, a request served while an answer was in
// flight, a refused frame taken as sent, S3 running while a request was still arriving.
// @verifies REQ-BOOT-012
import boot
import comm.isotp
import driver.can

const srx = u32(0x7C0)
const stx = u32(0x7C8)

// FakeChan is a channel: frames queued for recv, frames sent recorded, a send that can be refused
struct FakeChan {
mut:
	rx      []can.Frame
	tx      []can.Frame
	refuse  bool
	pending int // frames handed to the "controller" and not yet on the wire (tx_idle)
}

fn (mut c FakeChan) recv(mut f can.Frame) bool {
	if c.rx.len == 0 {
		return false
	}
	f = c.rx[0]
	c.rx.delete(0)
	return true
}

fn (mut c FakeChan) send(f can.Frame) bool {
	if c.refuse {
		return false
	}
	c.tx << f
	return true
}

fn (c &FakeChan) tx_ready() bool {
	return true
}

fn (mut c FakeChan) tx_idle() bool {
	if c.pending > 0 {
		c.pending--
	}
	return c.pending == 0
}

// FakeServer answers 0x22 with a long (multi-frame) record and 0x11 with 51 01 + a pending reset;
// it keeps its own S3 on the heard() stamps, as boot.Prog and uds.Server do
struct FakeServer {
mut:
	handled  int
	reset    bool
	session  u8 = 3
	last     u64
	silent_s u64 = 5_000_000
}

fn (mut s FakeServer) handle(req &u8, n int, resp &u8) int {
	s.handled++
	sid := unsafe { req[0] }
	if sid == 0x11 {
		s.reset = true
		unsafe {
			resp[0] = 0x51
			resp[1] = 0x01
		}
		return 2
	}
	for i in 0 .. 40 {
		unsafe {
			resp[i] = u8(0x62 + i)
		}
	}
	return 40
}

fn (mut s FakeServer) heard(now u64) {
	s.last = now
}

fn (mut s FakeServer) tick(now u64) {
	if now > s.last && now - s.last > s.silent_s {
		s.session = 1
	}
}

fn (s &FakeServer) reset_due() bool {
	return s.reset
}

fn (mut s FakeServer) cancel_reset() {
	s.reset = false
}

fn new_link() isotp.Link {
	mut l := isotp.Link{}
	l.init_defaults()
	return l
}

// tester_frames: the frames a tester puts on the wire for `req` (single or first frame only when
// the request is long: the rest waits for the flow control)
fn tester_frames(mut t isotp.Link, now u64, req []u8) []can.Frame {
	assert t.send(&req[0], req.len)
	mut out := []can.Frame{}
	mut p := isotp.Pdu{}
	for t.poll(now, mut p) {
		mut f := can.Frame{
			id:  srx
			len: 8
		}
		for i in 0 .. 8 {
			f.data[i] = p.data[i]
		}
		out << f
		p = isotp.Pdu{}
	}
	return out
}

struct Bufs {
mut:
	req  [isotp.max_payload]u8
	resp [isotp.max_payload]u8
}

fn step(mut s FakeServer, mut l isotp.Link, now u64, mut ch FakeChan, mut b Bufs) bool {
	return serve_step(mut s, mut l, srx, stx, now, mut ch, &b.req[0], &b.resp[0])
}

// a frame shorter than its PCI says is dropped, never read as a request
fn test_a_truncated_frame_is_no_request() {
	mut s := FakeServer{}
	mut l := new_link()
	mut ch := FakeChan{}
	mut b := Bufs{}
	mut f := can.Frame{
		id:  srx
		len: 2 // says 3 bytes of payload, carries 1
	}
	f.data[0] = 0x03
	f.data[1] = 0x22
	ch.rx << f
	step(mut s, mut l, 0, mut ch, mut b)
	assert s.handled == 0
	assert ch.tx.len == 0
}

// a request completing while an answer is still being sent is dropped — an overlapping 0x11 is never
// served (and so never resets without its own answer)
fn test_a_request_while_an_answer_is_in_flight_is_dropped() {
	mut s := FakeServer{}
	mut l := new_link()
	mut ch := FakeChan{}
	mut b := Bufs{}
	mut t := new_link()
	ch.rx << tester_frames(mut t, 0, [u8(0x22), 0xF1, 0x90])
	step(mut s, mut l, 0, mut ch, mut b)
	assert s.handled == 1
	assert ch.tx.len == 1 && ch.tx[0].data[0] >> 4 == 1, 'a first frame, waiting for flow control'
	// no flow control from the tester: the answer is still in flight when 0x11 arrives
	mut t2 := new_link()
	ch.rx << tester_frames(mut t2, 1000, [u8(0x11), 0x01])
	due := step(mut s, mut l, 1000, mut ch, mut b)
	assert s.handled == 1, 'served a request while its previous answer was in flight'
	assert !s.reset && !due
}

// a frame the channel refuses aborts the answer, and the reset it announced does not happen
fn test_a_refused_frame_aborts_the_answer_and_its_reset() {
	mut s := FakeServer{}
	mut l := new_link()
	mut ch := FakeChan{
		refuse: true
	}
	mut b := Bufs{}
	mut t := new_link()
	ch.rx << tester_frames(mut t, 0, [u8(0x11), 0x01])
	due := step(mut s, mut l, 0, mut ch, mut b)
	assert s.handled == 1
	assert !due && !s.reset, 'reset with its answer refused by the channel'
	assert l.idle(), 'the refused transfer is abandoned, not left half-sent'
	// the same request with the channel accepting: due once the answer has left
	mut s2 := FakeServer{}
	mut l2 := new_link()
	mut ch2 := FakeChan{}
	mut t2 := new_link()
	ch2.rx << tester_frames(mut t2, 0, [u8(0x11), 0x01])
	assert step(mut s2, mut l2, 0, mut ch2, mut b)
	assert ch2.tx.len == 1 && ch2.tx[0].data[1] == 0x51
}

// S3 is held while a multi-frame request is still arriving: a slow tester mid-request keeps its
// session however long the reception takes, within the link's own timeouts
fn test_s3_is_held_while_a_request_is_arriving() {
	mut s := FakeServer{
		silent_s: 3000
	}
	mut l := new_link()
	l.n_cr_us = 1_000_000 // the link's own consecutive-frame timeout, far beyond S3 here
	mut ch := FakeChan{}
	mut b := Bufs{}
	mut t := new_link()
	mut req := []u8{len: 20, init: 0x2E}
	req[0] = 0x2E
	ch.rx << tester_frames(mut t, 0, req) // the first frame only
	step(mut s, mut l, 0, mut ch, mut b)
	assert !l.idle(), 'the request is still arriving'
	for now in [u64(2000), 4000, 6000, 8000] {
		step(mut s, mut l, now, mut ch, mut b)
		assert s.session == 3, 'S3 ran mid-request at ${now}'
	}
}

// the drain waits for the controller, bounded: a reset's answer is on the wire first
fn test_the_wire_drain_waits_for_the_controller() {
	mut ch := FakeChan{
		pending: 3
	}
	wire_drain(mut ch, fake_clock)
	assert ch.pending == 0
}

fn fake_clock() u64 {
	return 0
}

// the bootloader's server through the same step: 0x11 answered, due once the answer has left
fn test_the_bootloader_runs_the_same_step() {
	mut p := boot.Prog{}
	p.init()
	mut l := new_link()
	mut ch := FakeChan{}
	mut b := Bufs{}
	mut t := new_link()
	ch.rx << tester_frames(mut t, 0, [u8(0x11), 0x01])
	due := serve_step(mut p, mut l, srx, stx, 0, mut ch, &b.req[0], &b.resp[0])
	assert due && p.reset_due()
	assert ch.tx.len == 1 && ch.tx[0].id == stx && ch.tx[0].data[..3] == [u8(0x02), 0x51, 0x01]
	// refused: the bootloader does not reset unanswered either
	mut q := boot.Prog{}
	q.init()
	mut l2 := new_link()
	mut ch2 := FakeChan{
		refuse: true
	}
	mut t2 := new_link()
	ch2.rx << tester_frames(mut t2, 0, [u8(0x11), 0x01])
	assert !serve_step(mut q, mut l2, srx, stx, 0, mut ch2, &b.req[0], &b.resp[0])
	assert !q.reset_due()
}
