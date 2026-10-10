module diagroute

import comm.diag
import comm.isotp
import driver.can

// Diagnostic routing on a DoIP gateway (REQ-NET-019): a diagnostic message whose target address is
// a node BEHIND the gateway — a CAN node with no network of its own — is forwarded to that node's
// physical request id on its bus, and each answer the node gives is handed back to the network
// tester as a diagnostic message from the node's logical address. The gateway is the node's tester
// on the bus: one ISO-TP link, half duplex, one exchange at a time (DoIP serves one tester).
//
// No-alloc and transport-agnostic, like the rest of comm/: the owner (the comm thread, which owns
// the buses) feeds received frames with on_frame, sends what pump yields, and moves requests in and
// responses out (driver/doipnet: the doip thread frames them).
//
//   accept(...)      a routed request from the network tester: forwarded, or why not (Verdict)
//   on_frame(...)    a frame from a bus: the active target's response id feeds the link
//   step(now)        timers: the request left, the target's answer is overdue
//   pump(now, ch)    the request's frames (and our flow control) onto the active target's bus
//   waiting()/head()/pop()  the answers waiting to go back to the tester
//
// Every routed request carries a ticket (the doip thread numbers them) and its answers carry it
// back: the doip thread sends only the answers to the latest request on the current connection, so
// an answer that comes after the tester gave up waiting is never read as the next request's.
//
// Access (REQ-NET-020): routing changes state on nodes no network tester could reach otherwise, so
// it needs the gateway's own unlock — the tester holds the configured security level of the
// gateway's server (comm/diag: an unlock earned over the network). The grant is kept for the
// tester's connection (`conn`, a number the doip thread changes with every connection), not for
// the gateway's session: a node's reprogramming outlasts the gateway's S3 many times over, and
// the tester must not lose the route in the middle of it. It is taken the pass the unlock is held
// (hold), not when the first routed request comes: a tester may unlock, then wait out S3 before
// it routes. A new connection starts unrouted.
//
// No field defaults (the _vinit rule): start from a zeroed Router — a __global — and call init().

// the most routes one gateway holds
pub const max_routes = 8

// how long the gateway waits for the target's next answer once the request has left: P2*max (5 s,
// the server's enhanced response timing, comm/uds) plus one second, so a target that answers
// responsePending within its P2* is never cut off before the tester's own P2* runs out
pub const answer_wait_us = u64(6_000_000)

// how long frames of an exchange may stop moving, either way, while something is in flight: the
// request's next frame waiting for room in the bus's transmit FIFO, or our flow control for an
// answer waiting for it — states ISO-TP's own timers do not bound (N_Bs runs only once a frame has
// left, N_Cr only once our flow control has). A bus that takes nothing (no node acknowledges,
// bus-off) must not hold every route busy; a transfer that keeps moving, however slowly (a target
// asking STmin 127 ms), is never cut off by it.
pub const stall_us = u64(5_000_000)

// how long a bus a route is on may wait, undrained, for the doip thread to take an answer once
// the queue is full: the gateway's own traffic on that bus (its routes, its signals) must not stall
// behind a tester that does not read — after this the bus is drained again, and an answer that
// finds the queue full is lost (counted)
pub const gate_hold_us = u64(20_000)

// answers queued for the doip thread: a responsePending and the final answer may complete in one
// pass (two single frames back to back), before the first has been taken
pub const queue_len = 2

pub struct Route {
pub mut:
	logical u16 // the target's DoIP logical address
	bus     u8  // the owner's index of the bus the target is on
	tx_id   u32 // the target's physical request id (standard id)
	rx_id   u32 // its response id
}

// Verdict is the router's answer to a routed request; the DoIP framing NACKs all but .accepted.
pub enum Verdict {
	accepted
	unknown_target // no such route
	locked         // the tester does not hold the gateway's unlock (REQ-NET-020)
	busy           // the previous request is still being sent to its target
	refused        // the link refused the request (too long, or empty)
}

// answers: does UDS answer `a` (n bytes) answer the request whose first bytes are `req` (rn of
// them, of a request `full` bytes long)? A negative answer names the service (0x7F SID NRC); a
// positive one is SID + 0x40 and echoes what identifies the request where the service echoes it —
// the sub-function (0x10, 0x11, 0x19, 0x27, 0x28, 0x29, 0x31, 0x3E, 0x85; its suppress bit aside:
// a suppressed request still owes the answer after a responsePending), then RoutineControl's
// routine identifier, the DTC (and the record) of a ReadDTCInformation 04 / 06, a data identifier (0x2E; 0x22: ANY of the requested ones — a server skips a
// DID it does not serve and answers with the next), TransferData's block sequence counter (0x36)
// — so a late answer to an earlier request of the same service is told apart wherever the protocol
// can tell it.
fn answers(a &u8, n int, req &u8, rn int, full int) bool {
	if n < 1 || rn < 1 {
		return false
	}
	unsafe {
		sid := req[0]
		if a[0] == 0x7F {
			return n >= 2 && a[1] == sid
		}
		if a[0] != sid + 0x40 {
			return false
		}
		if sid in [u8(0x10), 0x11, 0x19, 0x27, 0x28, 0x29, 0x31, 0x3E, 0x85] {
			if n < 2 || rn < 2 || a[1] != req[1] & 0x7F {
				return false
			}
			if sid == 0x31 { // ... and the routine
				return n >= 4 && rn >= 4 && a[2] == req[2] && a[3] == req[3]
			}
			if sid == 0x19 && (req[1] & 0x7F) in [u8(0x04), 0x06] {
				// ... and the one DTC it names, and the record asked for when one comes back (a
				// record not stored is absent from the answer; 0xFF asks for all of them, and an 06's
				// 0xFE for all the legislated OBD ones, 0x90..0xEF)
				if n < 6 || rn < 5 || a[2] != req[2] || a[3] != req[3] || a[4] != req[4] {
					return false
				}
				if n == 6 || rn < 6 || req[5] == 0xFF {
					return true
				}
				if req[5] == 0xFE && (req[1] & 0x7F) == 0x06 {
					return a[6] >= 0x90 && a[6] <= 0xEF
				}
				return a[6] == req[5]
			}
			return true
		}
		if sid == 0x22 {
			if n < 3 {
				return false
			}
			for i := 1; i + 1 < rn; i += 2 {
				if a[1] == req[i] && a[2] == req[i + 1] {
					return true
				}
			}
			// DIDs past what was kept of the request cannot be told: taken
			return full > rn
		}
		if sid == 0x2E {
			return n >= 3 && rn >= 3 && a[1] == req[1] && a[2] == req[2]
		}
		if sid == 0x36 {
			return n >= 2 && rn >= 2 && a[1] == req[1]
		}
		return true
	}
}

// how much of a request answers() compares: the service, its sub-function or identifiers — up to
// 15 data identifiers of a 0x22
const req_head_len = 31

pub struct Answer {
pub mut:
	logical u16 // the target it comes from
	ticket  u32 // the request it answers
	len     int
	data    [isotp.max_payload]u8
}

pub struct Router {
pub mut:
	routes   [max_routes]Route
	n_routes int
	level    u8 // the gateway's security level a tester must hold (set by init)
	// bench-observable counts
	forwarded u32 // requests sent on to a target
	answered  u32 // answers handed back
	timeouts  u32 // exchanges a target left unanswered within answer_wait_us, or that stalled
	failed    u32 // requests ISO-TP gave up sending (no flow control within N_Bs, an overflow)
	stale     u32 // answers to another request than the one in flight (a late one), dropped
	lost      u32 // answers that completed with the queue full (the doip thread fell behind)
mut:
	link       isotp.Link
	active     int // the route of the exchange in flight, -1 = none
	ticket     u32 // ... and the request's ticket
	req_head   [req_head_len]u8 // ... and its first bytes: an answer must echo them (answers)
	req_len    int
	req_full   int // ... of a request this long
	aborts     u32 // link.tx_aborts when it was accepted: a change is a send ISO-TP gave up
	moved_at   u64 // the last frame of the exchange either way (stall_us)
	sending    bool
	full_held  bool // the queue is full and its bus is held undrained since full_since (room)
	full_since u64
	deadline   u64 // while sending: the request must have left by; after: the next answer must have begun by
	granted    bool // the tester of the connection now open holds the route (REQ-NET-020)
	bound      bool // ... and its first routed request named that connection
	grant_conn u32
	queue      [queue_len]Answer
	q_head     int
	q_len      int
}

// init sets the flow control this side grants (bs blocks of consecutive frames before the next
// flow control: the gateway drains its bus's receive FIFO each pass, so the target never sends
// more frames in a burst than that FIFO holds) and the level a tester must hold.
pub fn (mut r Router) init(level u8, bs u8) {
	r.level = level
	r.link.bs = bs
	r.link.stmin = 0
	r.link.init_defaults()
	r.active = -1
}

// add appends a route; false when the table is full or the logical address is already routed.
pub fn (mut r Router) add(rt Route) bool {
	if r.n_routes >= max_routes || r.find(rt.logical) >= 0 {
		return false
	}
	r.routes[r.n_routes] = rt
	r.n_routes++
	return true
}

// find: the route to `logical`, or -1.
pub fn (r &Router) find(logical u16) int {
	for i in 0 .. r.n_routes {
		if r.routes[i].logical == logical {
			return i
		}
	}
	return -1
}

// accept takes one routed request from the network tester: route `idx` (the DoIP framing looked
// the target address up in the same table), the tester's connection `conn`, the request's
// `ticket`, and the security level the gateway's server holds for the network tester right now
// (`unlocked`, 0 = none). A request that supersedes an exchange still waiting for its answer ends
// that wait, and answers of it not yet taken are dropped: a tester sends its next request only
// after the previous answer or its own timeout.
pub fn (mut r Router) accept(idx int, req &u8, n int, conn u32, ticket u32, unlocked u8, now u64) Verdict {
	r.step(now) // the timers first: an exchange that has run out does not hold this one off
	if idx < 0 || idx >= r.n_routes {
		return .unknown_target
	}
	if n < 1 || n > isotp.max_payload {
		return .refused // refused before anything of the exchange in flight is touched
	}
	if r.granted && r.bound && r.grant_conn != conn {
		r.granted = false // a new connection: its tester authenticates for itself
		r.bound = false
	}
	r.hold(unlocked)
	if !r.granted {
		return .locked
	}
	if !r.bound {
		r.bound = true
		r.grant_conn = conn
	}
	if r.active >= 0 && r.sending {
		return .busy
	}
	// whatever the previous exchange left, half received or queued, is not this request's answer
	r.end_exchange()
	r.q_len = 0
	if !r.link.send(req, n) {
		return .refused
	}
	r.active = idx
	r.ticket = ticket
	r.req_len = if n < req_head_len { n } else { req_head_len }
	r.req_full = n
	for i in 0 .. r.req_len {
		r.req_head[i] = unsafe { req[i] }
	}
	r.aborts = r.link.tx_aborts
	r.moved_at = now
	r.sending = true
	r.forwarded++
	return .accepted
}

// hold: the network tester holds `unlocked` on the gateway's server now — the route level, and the
// grant is its connection's from here on, past S3, until cancel (the connection ended). The owner
// calls it every pass, not only with a request waiting, but never while a dropped connection is
// still untaken: the unlock it reads must be the open connection's own.
pub fn (mut r Router) hold(unlocked u8) {
	if r.level != 0 && unlocked == r.level {
		r.granted = true
	}
}

// settle: the request is no longer being sent — it left (the answer is due from now), or ISO-TP
// gave up on it (the target never got it whole: the exchange ends, the tester's P2 tells it)
fn (mut r Router) settle(now u64) {
	if r.active < 0 || !r.sending || r.link.busy() {
		return
	}
	if r.link.tx_aborts != r.aborts {
		r.failed++
		r.end_exchange()
		return
	}
	r.sending = false
	r.deadline = now + answer_wait_us
}

// overdue: no answer has begun within the wait (a reception in progress is ISO-TP's to bound,
// N_Cr) — the exchange ends, and the tester's own P2* tells it
fn (mut r Router) overdue(now u64) bool {
	if r.active < 0 || r.sending || now < r.deadline || !r.link.idle() {
		return false
	}
	r.timeouts++
	r.end_exchange()
	return true
}

// on_frame feeds one received frame from bus `bus`. True when the frame belonged to the exchange
// in flight; the owner then stops draining that bus when `full()` — an answer that completes with
// the queue full is lost.
pub fn (mut r Router) on_frame(bus u8, f &can.Frame, now u64) bool {
	if r.active < 0 || f.ext {
		return false
	}
	rt := r.routes[r.active]
	if rt.bus != bus || f.id != rt.rx_id {
		return false
	}
	// the timers first, whatever order the owner's pass runs in: a send ISO-TP gave up, a stalled
	// exchange, a reception N_Cr ended, an answer wait run out — a frame after that is no one's
	r.step(now)
	if r.active < 0 {
		return false
	}
	if r.sending && f.len > 0 && (f.data[0] & 0xF0) != 0x30 {
		// only flow control belongs to a request still leaving: an answer now is a late one to a
		// request the tester gave up on, and must not complete this one before it is even sent
		return true
	}
	// progress is what the link took (isotp progress: a frame of the answer, a flow control the
	// request waits for — a WAIT too, which N_Bs and WFTmax bound), not what arrived: a flow control
	// it was not waiting for, a reserved PCI, a truncated or out-of-sequence frame move nothing. Our
	// own sends count in pump.
	before := r.link.progress
	if diag.take_frame(mut r.link, now, f) {
		r.collect(now)
	}
	if r.link.progress != before {
		r.moved_at = now
	}
	return true
}

// collect moves a completed answer into the queue. A responsePending keeps the exchange open (the
// final answer follows within P2*); any other answer ends it.
fn (mut r Router) collect(now u64) {
	if r.q_len >= queue_len {
		r.link.abort_rx()
		r.lost++
		return
	}
	mut a := &r.queue[(r.q_head + r.q_len) % queue_len]
	a.len = r.link.take(&a.data[0])
	if a.len <= 0 {
		return
	}
	if !answers(&a.data[0], a.len, &r.req_head[0], r.req_len, r.req_full) {
		// a late answer to an earlier request (the tester gave up on it): not this one's — this
		// one's is still to come, within the same wait
		r.stale++
		return
	}
	a.logical = r.routes[r.active].logical
	a.ticket = r.ticket
	r.q_len++
	r.answered++
	if a.len >= 3 && a.data[0] == 0x7F && a.data[2] == 0x78 {
		r.deadline = now + answer_wait_us
	} else {
		r.end_exchange()
	}
}

// step runs the timers: a request ISO-TP gave up sending ends (settle); frames that stop moving
// for stall_us while something is in flight end it; once the request has left, the target's answer
// must begin within answer_wait_us (a reception in progress is ISO-TP's to bound, N_Cr) — an
// overdue exchange ends, and the tester's own P2* tells it.
pub fn (mut r Router) step(now u64) {
	r.link.tick(now)
	if r.active < 0 {
		return
	}
	r.settle(now)
	if r.active < 0 {
		return
	}
	if !r.link.idle() && now - r.moved_at >= stall_us {
		r.timeouts++
		r.end_exchange()
		return
	}
	r.overdue(now)
}

// pump sends the active exchange's frames — the request, our flow control for a multi-frame
// answer — on the active route's bus (the owner passes that bus's channel: active_bus). A frame
// the channel refuses aborts the request; the exchange ends, and the tester's P2 tells it.
pub fn (mut r Router) pump[H](now u64, mut ch H) {
	if r.active < 0 {
		return
	}
	tx_id := r.routes[r.active].tx_id
	mut f := can.Frame{}
	for ch.tx_ready() && diag.next_frame(mut r.link, tx_id, now, mut f) {
		if !ch.send(f) {
			r.link.abort_tx()
			r.end_exchange()
			return
		}
		r.moved_at = now
	}
	// the request's last frame has just left: the answer is due from now, not from the next step
	r.settle(now)
}

// cancel ends the exchange of a tester whose connection ended, and drops the answers it would have
// had: nobody takes them now, and a full queue would hold the bus undrained (room). The next
// connection starts unrouted.
pub fn (mut r Router) cancel() {
	r.end_exchange()
	r.q_len = 0
	r.full_held = false
	r.granted = false
	r.bound = false
}

// room: whether a bus a route is on may be drained now — while the answer queue has room, or once it
// has been full for gate_hold_us (then an answer that finds it full is lost, counted: the
// gateway's own traffic on that bus does not stall behind a tester that does not read).
pub fn (mut r Router) room(now u64) bool {
	if r.q_len < queue_len {
		r.full_held = false
		return true
	}
	if !r.full_held {
		r.full_held = true
		r.full_since = now
		return false
	}
	return now - r.full_since >= gate_hold_us
}

// active_bus: the bus the exchange in flight is on (its frames go there), or -1.
pub fn (r &Router) active_bus() int {
	return if r.active < 0 { -1 } else { int(r.routes[r.active].bus) }
}

// busy: frames of the exchange are in flight (a request going out, an answer coming in) or answers
// wait for the doip thread — the owner polls at its fastest meanwhile. Waiting for an answer alone
// is not busy: the target's first frame wakes the owner (the bus's receive interrupt).
pub fn (r &Router) busy() bool {
	return r.q_len > 0 || (r.active >= 0 && !r.link.idle())
}

// full: no room for another answer — the owner leaves the active bus's frames in its FIFO
// until the doip thread has taken one.
pub fn (r &Router) full() bool {
	return r.q_len >= queue_len
}

// waiting: answers queued for the doip thread.
pub fn (r &Router) waiting() int {
	return r.q_len
}

// head: the oldest answer waiting to go back (only while waiting() > 0).
pub fn (mut r Router) head() &Answer {
	return &r.queue[r.q_head]
}

// pop: the oldest answer has been handed over.
pub fn (mut r Router) pop() {
	if r.q_len == 0 {
		return
	}
	r.q_head = (r.q_head + 1) % queue_len
	r.q_len--
}

fn (mut r Router) end_exchange() {
	r.active = -1
	r.sending = false
	r.deadline = 0
	r.link.abort_tx()
	r.link.abort_rx() // a reception in progress belongs to the exchange that ended
}
