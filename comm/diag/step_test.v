module diag

// The shared transport step (step.v) — once, for every owner: the application's Connection calls its
// pieces, the bootloader runs serve_step whole. Each case is a defect a hand-written serve loop had
// (codex #367 r4-r5): a truncated frame read as a request, a request served while an answer was in
// flight, a refused frame taken as sent, S3 running while a request was still arriving.
// @verifies REQ-BOOT-012 REQ-DIAG-028 REQ-DIAG-037 REQ-CAN-TP-013 REQ-CAN-TP-018
// @verifies REQ-CAN-TP-040 REQ-CAN-TP-042
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
	stalled bool // the controller takes no frame (tx_ready false)
	pending int // frames handed to the "controller" and not yet on the wire (tx_idle)
	stuck   bool // nothing leaves the controller (a bus-off): tx_idle never true
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
	return !c.stalled
}

fn (mut c FakeChan) tx_idle() bool {
	if c.stuck {
		return false
	}
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
	last_len int // the length of the last request handled
	reset    bool
	session  u8 = 3
	last     u64
	silent_s u64 = 5_000_000
}

fn (mut s FakeServer) handle(req &u8, n int, resp &u8) int {
	s.handled++
	s.last_len = n
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

fn (s &FakeServer) work_pending() bool {
	return false
}

fn (s &FakeServer) work_awaiting() bool {
	return false
}

fn (mut s FakeServer) work_left() {}

fn (mut s FakeServer) work_lost() {}

fn (mut s FakeServer) work(_ u64, _ &u8) int {
	return 0
}

fn zero_clock() u64 {
	return 0
}

fn new_link() isotp.Link {
	return link_at(isotp.default_message)
}

// link_at: a link with `m`-byte buffers of its own
fn link_at(m int) isotp.Link {
	mut l := isotp.Link{}
	l.init_defaults()
	rxb := []u8{len: m}
	txb := []u8{len: m}
	l.bind_rx(&rxb[0], m)
	l.bind_tx(&txb[0], m)
	return l
}

// tester_frames: the frames a tester puts on the wire for `req` (single or first frame only when
// the request is long: the rest waits for the flow control)
fn tester_frames(mut t isotp.Link, now u64, req []u8) []can.Frame {
	assert t.send(&req[0], req.len)
	mut out := []can.Frame{}
	mut p := isotp.Pdu{}
	for t.poll(now, mut p) {
		out << wire(srx, p)
		p = isotp.Pdu{}
	}
	return out
}

// wire: a PDU as the frame it goes out as on `id`, at its length
fn wire(id u32, p isotp.Pdu) can.Frame {
	mut f := can.Frame{
		id:  id
		len: u8(p.len)
	}
	for i in 0 .. p.len {
		f.data[i] = p.data[i]
	}
	return f
}

struct Bufs {
mut:
	req  [isotp.message_limit]u8
	resp [isotp.message_limit]u8
}

fn step(mut s FakeServer, mut l isotp.Link, now u64, mut ch FakeChan, mut b Bufs) bool {
	return serve_step(mut s, mut l, srx, stx, false, now, mut ch, &b.req[0], &b.resp[0], zero_clock)
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
	p.init(isotp.default_message)
	mut l := new_link()
	mut ch := FakeChan{}
	mut b := Bufs{}
	mut t := new_link()
	ch.rx << tester_frames(mut t, 0, [u8(0x11), 0x01])
	due := serve_step(mut p, mut l, srx, stx, false, 0, mut ch, &b.req[0], &b.resp[0], zero_clock)
	assert due && p.reset_due()
	assert ch.tx.len == 1 && ch.tx[0].id == stx && ch.tx[0].data[..3] == [u8(0x02), 0x51, 0x01]
	// refused: the bootloader does not reset unanswered either
	mut q := boot.Prog{}
	q.init(isotp.default_message)
	mut l2 := new_link()
	mut ch2 := FakeChan{
		refuse: true
	}
	mut t2 := new_link()
	ch2.rx << tester_frames(mut t2, 0, [u8(0x11), 0x01])
	assert !serve_step(mut q, mut l2, srx, stx, false, 0, mut ch2, &b.req[0], &b.resp[0], zero_clock)
	assert !q.reset_due()
}

// two complete requests already queued in one batch: the first is served and the second stays
// queued — draining both into the link would overwrite the first, and a queued 0x11 would bypass
// the busy guard because no answer is in flight yet
fn test_queued_requests_are_taken_one_at_a_time() {
	mut s := FakeServer{}
	mut l := new_link()
	mut ch := FakeChan{}
	mut b := Bufs{}
	mut t := new_link()
	ch.rx << tester_frames(mut t, 0, [u8(0x22), 0xF1, 0x90])
	mut t2 := new_link()
	ch.rx << tester_frames(mut t2, 0, [u8(0x11), 0x01])
	step(mut s, mut l, 0, mut ch, mut b)
	assert s.handled == 1 && !s.reset, 'the first queued request was overwritten by the second'
	assert ch.rx.len == 1, 'the second request was drained into the link before the first was served'
	// its answer is still in flight (no flow control), so the 0x11 is dropped, not served
	step(mut s, mut l, 1000, mut ch, mut b)
	assert s.handled == 1 && !s.reset
}

// routine work the bootloader answered pending (an erase): each pass with the link idle drains the
// wire FIRST — the previous response must be on the bus before an erase stalls the chip — then
// erases one unit and sends what follows: 0x78 while units remain, the routine's answer after
__global g_step_ch &FakeChan
__global g_step_pending_at_erase []int

fn ram_erase(_ voidptr, _ u32, _ u32) bool {
	g_step_pending_at_erase << g_step_ch.pending
	return true
}

fn ram_read(_ voidptr, _ u32, out &u8, len u32) bool {
	for i in 0 .. len {
		unsafe {
			out[i] = 0xFF
		}
	}
	return true
}

fn test_routine_work_steps_once_the_wire_is_drained() {
	mut p := boot.Prog{}
	p.init(isotp.default_message)
	p.app_base = 0x0802_0000
	p.app_size = 0x0004_0000
	p.erase_unit = 0x0001_0000 // four units
	p.flash = boot.FlashOps{
		erase: ram_erase
		read:  ram_read
	}
	mut ch := &FakeChan{}
	g_step_ch = ch
	g_step_pending_at_erase = []int{}
	mut l := new_link()
	mut b := Bufs{}
	mut resp := []u8{len: 16}
	prog := [u8(0x10), 0x02]
	assert p.handle(&prog[0], 2, unsafe { &resp[0] }) > 0
	er := [u8(0x31), 0x01, 0xFF, 0x00, 0x08, 0x02, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00]
	assert p.handle(&er[0], er.len, unsafe { &resp[0] }) == 3 && resp[2] == 0x78
	mut answers := [][]u8{}
	for i in 0 .. 8 {
		ch.pending = 3 // what the previous response left in the controller
		serve_step(mut p, mut l, srx, stx, false, u64(i), mut ch, &b.req[0], &b.resp[0], zero_clock)
		for f in ch.tx {
			answers << f.data[..f.data[0] + 1].clone()
		}
		ch.tx.clear()
		if p.work == 0 {
			break // the routine answered
		}
	}
	assert g_step_pending_at_erase == [0, 0, 0, 0], 'an erase ran with a response still in the controller'
	assert answers == [[u8(0x03), 0x7F, 0x31, 0x78], [u8(0x03), 0x7F, 0x31, 0x78],
		[u8(0x03), 0x7F, 0x31, 0x78], [u8(0x05), 0x71, 0x01, 0xFF, 0x00, 0x00]], answers.str()
}

// a response still on its way out of the link holds the next step back
fn test_routine_work_waits_for_the_link() {
	mut p := boot.Prog{}
	p.init(isotp.default_message)
	p.app_base = 0x0802_0000
	p.app_size = 0x0004_0000
	p.flash = boot.FlashOps{
		erase: ram_erase
		read:  ram_read
	}
	mut ch := &FakeChan{
		stalled: true
	}
	g_step_ch = ch
	g_step_pending_at_erase = []int{}
	mut l := new_link()
	mut b := Bufs{}
	mut resp := []u8{len: 16}
	prog := [u8(0x10), 0x02]
	p.handle(&prog[0], 2, unsafe { &resp[0] })
	er := [u8(0x31), 0x01, 0xFF, 0x00, 0x08, 0x02, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00]
	n := p.handle(&er[0], er.len, unsafe { &resp[0] })
	assert l.send(unsafe { &resp[0] }, n) // the 0x78, not yet taken by the controller
	serve_step(mut p, mut l, srx, stx, false, 0, mut ch, &b.req[0], &b.resp[0], zero_clock)
	assert g_step_pending_at_erase.len == 0, 'a step with the previous response still in the link'
	ch.stalled = false
	serve_step(mut p, mut l, srx, stx, false, 1, mut ch, &b.req[0], &b.resp[0], zero_clock)
	assert g_step_pending_at_erase.len == 1
}

// a routine's 0x78 the controller refuses is lost: the next pass says it again and erases nothing
// until one has left; refused every time, the routine ends refused — never the erase unannounced
fn test_a_refused_pending_answer_is_said_again_before_any_erase() {
	mut p := boot.Prog{}
	p.init(isotp.default_message)
	p.app_base = 0x0802_0000
	p.app_size = 0x0004_0000
	p.erase_unit = 0x0002_0000 // two units
	p.flash = boot.FlashOps{
		erase: ram_erase
		read:  ram_read
	}
	mut ch := &FakeChan{}
	g_step_ch = ch
	g_step_pending_at_erase = []int{}
	mut l := new_link()
	mut b := Bufs{}
	mut resp := []u8{len: 16}
	prog := [u8(0x10), 0x02]
	p.handle(&prog[0], 2, unsafe { &resp[0] })
	er := [u8(0x31), 0x01, 0xFF, 0x00, 0x08, 0x02, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00]
	n := p.handle(&er[0], er.len, unsafe { &resp[0] })
	ch.refuse = true
	assert !l.send(unsafe { &resp[0] }, n) || true
	// the 0x78 is refused on its way out: lost, said again, nothing erased
	l.abort_tx()
	p.work_lost()
	serve_step(mut p, mut l, srx, stx, false, 0, mut ch, &b.req[0], &b.resp[0], zero_clock)
	assert g_step_pending_at_erase.len == 0, 'erased with its 0x78 refused'
	ch.refuse = false
	for i in 1 .. 6 {
		serve_step(mut p, mut l, srx, stx, false, u64(i), mut ch, &b.req[0], &b.resp[0], zero_clock)
		if p.work == 0 {
			break
		}
	}
	assert g_step_pending_at_erase.len == 2, 'both units, once announced'
	mut said := []u8{}
	for f in ch.tx {
		said << f.data[1]
	}
	assert said == [u8(0x7F), 0x7F, 0x71], 'the 0x78 again, a unit, 0x78, a unit, the answer: ${said}'
	// refused every time: the routine ends refused, nothing erased
	mut q := boot.Prog{}
	q.init(isotp.default_message)
	q.app_base = 0x0802_0000
	q.app_size = 0x0004_0000
	q.erase_unit = 0x0002_0000
	q.flash = p.flash
	g_step_pending_at_erase = []int{}
	q.handle(&prog[0], 2, unsafe { &resp[0] })
	q.handle(&er[0], er.len, unsafe { &resp[0] })
	q.work_lost()
	mut ch2 := &FakeChan{
		refuse: true
	}
	g_step_ch = ch2
	mut l2 := new_link()
	for i in 0 .. 10 {
		serve_step(mut q, mut l2, srx, stx, false, u64(i), mut ch2, &b.req[0], &b.resp[0], zero_clock)
	}
	assert q.work == 0 && g_step_pending_at_erase.len == 0, 'given up without erasing'
}

// the routine's first 0x78 — its answer to the request — refused by the controller is lost: the
// pass says it again and runs nothing (here: the image check, not done unannounced)
fn test_a_refused_first_pending_answer_holds_the_routine() {
	mut p := boot.Prog{}
	p.init(isotp.default_message)
	p.app_base = 0x0802_0000
	p.app_size = 0x0004_0000
	p.flash = boot.FlashOps{
		erase: ram_erase
		read:  ram_read
	}
	mut resp := []u8{len: 16}
	prog := [u8(0x10), 0x02]
	p.handle(&prog[0], 2, unsafe { &resp[0] })
	mut ch := &FakeChan{
		refuse: true
	}
	mut l := new_link()
	mut b := Bufs{}
	mut t := new_link()
	ch.rx << tester_frames(mut t, 0, [u8(0x31), 0x01, 0xFF, 0x01])
	serve_step(mut p, mut l, srx, stx, false, 0, mut ch, &b.req[0], &b.resp[0], zero_clock)
	assert p.work != 0 && p.work_resend && !p.work_ready, 'the check ran with its 0x78 refused'
}

__global g_step_t u64

// a clock that moves: a drain that never completes runs out
fn moving_clock() u64 {
	g_step_t += drain_us / 4
	return g_step_t
}

// start_erase: the erase request served (its 0x78 handed to the transport, not yet confirmed)
fn start_erase(mut p boot.Prog) {
	mut resp := []u8{len: 16}
	er := [u8(0x31), 0x01, 0xFF, 0x00, 0x08, 0x02, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00]
	assert p.handle(&er[0], er.len, unsafe { &resp[0] }) == 3 && resp[2] == 0x78
}

fn two_unit_prog() boot.Prog {
	mut p := boot.Prog{}
	p.init(isotp.default_message)
	p.app_base = 0x0802_0000
	p.app_size = 0x0004_0000
	p.erase_unit = 0x0002_0000 // two units
	p.flash = boot.FlashOps{
		erase: ram_erase
		read:  ram_read
	}
	mut resp := []u8{len: 16}
	prog := [u8(0x10), 0x02]
	p.handle(&prog[0], 2, unsafe { &resp[0] })
	return p
}

// a drain that runs out (the 0x78 still in the controller: a bus-off) confirms nothing: the 0x78
// is lost, said again, and no unit is erased until one has drained; stuck for good, the routine
// ends — its refusal lost too, given up — with nothing erased and nothing holding the session
fn test_a_drain_that_runs_out_is_a_lost_response() {
	mut p := two_unit_prog()
	mut ch := &FakeChan{
		stuck: true
	}
	g_step_ch = ch
	g_step_pending_at_erase = []int{}
	mut l := new_link()
	mut b := Bufs{}
	start_erase(mut p)
	for i in 0 .. 3 {
		serve_step(mut p, mut l, srx, stx, false, u64(i), mut ch, &b.req[0], &b.resp[0], moving_clock)
	}
	assert g_step_pending_at_erase.len == 0, 'erased with its 0x78 undrained'
	assert ch.tx.len == 3, 'the 0x78 said again, each time it ran out'
	ch.stuck = false
	for i in 3 .. 12 {
		serve_step(mut p, mut l, srx, stx, false, u64(i), mut ch, &b.req[0], &b.resp[0], moving_clock)
		if p.work == 0 {
			break
		}
	}
	assert g_step_pending_at_erase.len == 2 && p.work == 0, 'both units, then the answer confirmed'
	// stuck for good
	mut q := two_unit_prog()
	mut ch2 := &FakeChan{
		stuck: true
	}
	g_step_ch = ch2
	g_step_pending_at_erase = []int{}
	mut l2 := new_link()
	start_erase(mut q)
	for i in 0 .. 40 {
		serve_step(mut q, mut l2, srx, stx, false, u64(i), mut ch2, &b.req[0], &b.resp[0], moving_clock)
	}
	assert q.work == 0 && g_step_pending_at_erase.len == 0, 'given up without erasing'
	mut said := []u8{}
	for f in ch2.tx {
		said << f.data[3]
	}
	assert said.filter(it == 0x78).len == boot.work_resend_max, 'the 0x78 bounded: ${said}'
	assert said.filter(it == 0x72).len == boot.work_resend_max + 1, 'the refusal bounded: ${said}'
}

// the routine's answer is in flight until drained, like its 0x78s: one that does not drain is
// sent again — the unit not erased twice — and confirmed once the wire takes it
fn test_an_undrained_answer_is_sent_again() {
	mut p := two_unit_prog()
	p.erase_unit = 0
	mut ch := &FakeChan{}
	g_step_ch = ch
	g_step_pending_at_erase = []int{}
	mut l := new_link()
	mut b := Bufs{}
	start_erase(mut p)
	serve_step(mut p, mut l, srx, stx, false, 1, mut ch, &b.req[0], &b.resp[0], moving_clock) // erase, 0x71
	assert g_step_pending_at_erase.len == 1 && p.work != 0
	ch.stuck = true
	serve_step(mut p, mut l, srx, stx, false, 2, mut ch, &b.req[0], &b.resp[0], moving_clock)
	assert p.work != 0, 'an undrained answer confirmed'
	ch.stuck = false
	for i in 3 .. 6 {
		serve_step(mut p, mut l, srx, stx, false, u64(i), mut ch, &b.req[0], &b.resp[0], moving_clock)
	}
	assert p.work == 0 && g_step_pending_at_erase.len == 1, 'confirmed, erased once'
	mut said := []u8{}
	for f in ch.tx {
		said << f.data[1]
	}
	assert said == [u8(0x71), 0x71], 'the answer again: ${said}'
}

// @verifies REQ-CAN-TP-014 REQ-BOOT-020
// at the limit the step reassembles a TransferData as long as a 4095-byte connection's bootloader
// advertises (4066 bytes), segmented and paced by its flow control, into the owner's buffers
fn test_the_step_takes_a_block_as_long_as_the_maximum_holds() {
	mut s := FakeServer{}
	mut l := link_at(isotp.message_limit)
	mut ch := FakeChan{}
	mut b := Bufs{}
	mut t := link_at(isotp.message_limit)
	n := boot.block_data_for(isotp.message_limit) + 2
	assert n == 4066
	mut req := []u8{len: n, init: u8(index)}
	req[0] = 0x36
	assert t.send(unsafe { &req[0] }, n)
	for now := u64(0); now < 2_000_000 && s.handled == 0; now += 1000 {
		mut p := isotp.Pdu{}
		for t.poll(now, mut p) {
			ch.rx << wire(srx, p)
		}
		step(mut s, mut l, now, mut ch, mut b)
		for f in ch.tx {
			t.on_frame(now, pdu_of(&f))
		}
		ch.tx.clear()
	}
	assert s.handled == 1 && s.last_len == n
	for i in 1 .. n {
		assert b.req[i] == u8(i)
	}
}

// @verifies REQ-CAN-TP-028
// pdu_of carries a frame at its length and never the stale bytes past it; a frame of no bytes is no
// request
fn test_pdu_of_takes_only_the_bytes_that_arrived() {
	mut f := can.Frame{
		id:  srx
		len: 12
	}
	for i in 0 .. 64 {
		f.data[i] = 0xEE
	}
	p := pdu_of(&f)
	assert p.len == 12 && p.data[11] == 0xEE && p.data[12] == 0
	f.len = 200 // past any frame: 64
	assert pdu_of(&f).len == 64
	mut l := new_link()
	f.len = 0
	assert !take_frame(mut l, 0, &f) && l.idle()
	f.len = 200 // a length no controller delivers is refused, never clipped to 64 and read
	f.data[0] = 0x00 // an escape single frame, valid in a 64-byte frame
	f.data[1] = 0x02
	f.data[2] = 0x3E
	f.data[3] = 0x00
	assert !take_frame(mut l, 0, &f) && l.idle()
	f.len = 64
	assert take_frame(mut l, 0, &f), 'the same frame at 64 bytes is a request'
}

// @verifies REQ-CAN-TP-027 REQ-CAN-TP-028
// the step carries CAN-FD frames both ways: a tester at TX_DL 64 sends a 200-byte request in
// 64-byte frames, which reach the link at their length and reassemble; the server's link at TX_DL
// 64 answers its 40 bytes behind the escape in a 48-byte frame, and its flow control is 8 bytes
fn test_the_step_carries_fd_frames_both_ways() {
	mut s := FakeServer{}
	mut l := new_link()
	l.tx_dl = 64
	mut ch := FakeChan{}
	mut b := Bufs{}
	mut t := new_link()
	t.tx_dl = 64
	req := []u8{len: 200, init: u8(index + 1)}
	ch.rx << tester_frames(mut t, 0, req)
	assert ch.rx.len == 1 && ch.rx[0].len == 64
	step(mut s, mut l, 0, mut ch, mut b)
	assert ch.tx.len == 1 && ch.tx[0].len == 8 && ch.tx[0].data[0] == 0x30
	t.on_frame(0, pdu_of(&ch.tx[0]))
	ch.tx.clear()
	mut p := isotp.Pdu{}
	for t.poll(1000, mut p) {
		ch.rx << wire(srx, p)
	}
	assert ch.rx.map(it.len) == [u8(64), 64, 16]
	step(mut s, mut l, 1000, mut ch, mut b)
	assert s.handled == 1 && s.last_len == 200
	for i in 0 .. 200 {
		assert b.req[i] == u8(i + 1)
	}
	assert ch.tx.len == 1
	f := ch.tx[0]
	assert f.id == stx && f.len == 48 && f.data[0] == 0x00 && f.data[1] == 40
	for i in 0 .. 40 {
		assert f.data[2 + i] == u8(0x62 + i)
	}
	for i in 42 .. 48 {
		assert f.data[i] == 0
	}
}

// @verifies REQ-CAN-TP-026
// the bootloader's link, configured as its image configures it (boot.LinkCfg — BOOT_BS, BOOT_STMIN,
// BOOT_TX_DL), answers its boot.Prog through the bootloader's own serve step at the node's TX_DL: a
// 33-byte DID answer behind the escape in one 48-byte frame at 64, a first frame of 8 at 8; the flow
// control it answers a long request with is 8 bytes and carries the node's BS and STmin; and the
// configuration gives the link ISO-TP's timers, N_Ar among them
fn test_the_bootloader_answers_at_its_nodes_tx_dl() {
	for dl in [u8(8), 64] {
		mut p := boot.Prog{}
		p.init(isotp.default_message)
		ident := []u8{len: 30, init: u8(0x41 + index)}
		assert p.add_did(0xF190, &ident[0], ident.len)
		mut l := isotp.Link{}
		boot.LinkCfg{
			bs:    4
			stmin: 2
			tx_dl: dl
		}.configure(mut l)
		assert l.n_bs_us == 1_000_000 && l.n_cr_us == 1_000_000 && l.n_ar_us == 1_000_000
			&& l.wft_max == 16
		rxb := []u8{len: isotp.default_message}
		txb := []u8{len: isotp.default_message}
		l.bind_rx(&rxb[0], rxb.len)
		assert l.bind_tx(&txb[0], txb.len)
		mut ch := FakeChan{}
		mut b := Bufs{}
		mut t := new_link()
		ch.rx << tester_frames(mut t, 0, [u8(0x22), 0xF1, 0x90])
		serve_step(mut p, mut l, srx, stx, false, 0, mut ch, &b.req[0], &b.resp[0], zero_clock)
		assert ch.tx.len == 1, 'TX_DL ${dl}'
		f := ch.tx[0]
		if dl == 64 {
			assert f.len == 48 && f.data[..5] == [u8(0x00), 33, 0x62, 0xF1, 0x90], f.str()
			assert f.data[5..35] == ident
		} else {
			assert f.len == 8 && f.data[..5] == [u8(0x10), 33, 0x62, 0xF1, 0x90], f.str()
		}
		ch.tx.clear()
		// a first frame of a long request: the flow control it owes, 8 bytes, BS 4 and STmin 2
		mut ff := can.Frame{
			id:  srx
			len: 8
		}
		ff.data[0] = 0x10
		ff.data[1] = 40
		l.abort_tx() // the answer's rest is not this case's
		ch.rx << ff
		serve_step(mut p, mut l, srx, stx, false, 1000, mut ch, &b.req[0], &b.resp[0], zero_clock)
		assert ch.tx.len == 1 && ch.tx[0].len == 8 && ch.tx[0].data[..3] == [u8(0x30), 4, 2], 'TX_DL ${dl}'
	}
}

// the step on 29-bit ids (the bootloader of a node on 29-bit or normal fixed addressing): a request
// is taken only as a 29-bit frame on rx_id, and every frame of the answer goes out 29-bit on tx_id —
// the tester's flow control taken only in that format too
fn test_a_29_bit_step_serves_29_bit_frames_only() {
	rx29 := u32(0x18DA20F1)
	tx29 := u32(0x18DAF120)
	mut s := FakeServer{}
	mut l := new_link()
	mut ch := FakeChan{}
	mut b := Bufs{}
	mut t := new_link()
	mut req := tester_frames(mut t, 0, [u8(0x22), 0xF1, 0x90])
	req[0].id = rx29 // the rx number, as an 11-bit frame: another frame
	ch.rx << req
	serve_step(mut s, mut l, rx29, tx29, true, 0, mut ch, &b.req[0], &b.resp[0], zero_clock)
	assert s.handled == 0 && ch.tx.len == 0
	req[0].ext = true
	ch.rx << req
	serve_step(mut s, mut l, rx29, tx29, true, 0, mut ch, &b.req[0], &b.resp[0], zero_clock)
	assert s.handled == 1
	assert ch.tx.len == 1 && ch.tx[0].ext && ch.tx[0].id == tx29 // the first frame of 40 bytes
	t.on_frame(0, pdu_of(&ch.tx[0]))
	mut p := isotp.Pdu{}
	assert t.poll(0, mut p) // the tester's flow control
	mut fc := wire(rx29, p)
	ch.rx << fc // as an 11-bit frame: not this connection's, nothing more is sent
	serve_step(mut s, mut l, rx29, tx29, true, 1, mut ch, &b.req[0], &b.resp[0], zero_clock)
	assert ch.tx.len == 1
	fc.ext = true
	ch.rx << fc
	serve_step(mut s, mut l, rx29, tx29, true, 2, mut ch, &b.req[0], &b.resp[0], zero_clock)
	assert ch.tx.len == 6 // the first frame and five consecutive frames: 6 + 5 * 7 >= 40
	assert ch.tx.all(it.ext && it.id == tx29)
}

// an 11-bit step skips a 29-bit frame on its rx number (the bootloader of an 11-bit node)
fn test_an_11_bit_step_skips_29_bit_frames() {
	mut s := FakeServer{}
	mut l := new_link()
	mut ch := FakeChan{}
	mut b := Bufs{}
	mut t := new_link()
	mut req := tester_frames(mut t, 0, [u8(0x22), 0xF1, 0x90])
	req[0].ext = true
	ch.rx << req
	step(mut s, mut l, 0, mut ch, mut b)
	assert s.handled == 0 && ch.tx.len == 0
}
