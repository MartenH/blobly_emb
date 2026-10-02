module diag

import comm.isotp
import comm.uds
import driver.can

// Connection is a node's diagnostic server on its one ISO-TP connection (docs/diagnostics.md §2):
// the link, the UDS server, their buffers, and the ORDER a pass runs them in — protocol behaviour,
// the same on every owner. The owner (a bus bridge on the host; the ThreadX comm thread from R2)
// brings the clock, the channel and the 0x28 gating of its own application frames.
//
// A pass, in this order: housekeep → the owner samples its receive gate → the rx drain hands every
// frame to on_frame (breaking on .request, re-sampling the gate on .served) → serve → produce until
// the channel is not ready.
//
// No field defaults (the _vinit rule): start from a zeroed Connection — a fresh state struct or a
// __global — and call init().
pub struct Connection {
pub mut:
	link          isotp.Link
	server        uds.Server
	rx_id         u32 // physical requests (standard id)
	tx_id         u32 // responses
	functional_id u32 // functional requests, shared by every server on the bus; 0 = none
	// refresh writes the live-signal DIDs into the server it is handed. It runs right before every
	// dispatch, physical or functional, so a read answers with the value current then. nil = the
	// node has no live DIDs.
	refresh fn (mut srv uds.Server)
	// owner_resets: the owner performs an answered ECUReset itself (reset_due) — a target restarts
	// the MCU once its controller has sent the answer. Otherwise the diagnostic state returns to
	// power-on here, which is all a host bridge can do.
	owner_resets bool
mut:
	req  [isotp.max_payload]u8
	resp [isotp.max_payload]u8
	// a request served over another transport (serve_remote): the session in force was set by it
	// (a request that did not change it does not move this), and a reset it asked for waits until
	// that transport has sent the answer
	remote_owns   bool
	remote_unsent bool
	// the pending reset (server.reset_req) was asked over the other transport: a bus transfer that
	// fails cannot cancel it — that answer was not the reset's
	reset_remote bool
	// the security level unlocked (server.unlocked) was earned over the other transport. An unlock
	// belongs to the transport that ran 0x27: a request over the other one sees the server locked
	// (REQ-NET-012 — a network tester never inherits a bus tester's unlock, nor the reverse)
	unlock_remote bool
	// the SecurityAccess exchange in progress (a seed answered, its key not yet sent) per transport,
	// [0] the bus's and [1] the other's: a seed asked over one never replaces the other's challenge.
	// Kept with the session ENTRY it began in (server.session_epoch) — any session entry since,
	// re-entering the same session included, by either transport, S3 or a reset, cancels it, as the
	// server cancels its own
	// the other transport's unlock a reset request hid: back if the reset is cancelled, gone with it
	// if it happens
	held_back        u8
	held_back_remote bool // whose it is: it comes back to its owner, and goes with a dropped one
	held_back_epoch  u32  // the session entry it belongs to: a session entry since voids it
	sa_level [2]u8
	sa_seed  [2][uds.seed_len]u8
	sa_epoch [2]u32
}

// Rx is what on_frame did with a received frame, for the owner's drain.
pub enum Rx {
	other   // not this connection's
	taken   // consumed; nothing for the owner to do
	request // it completed a request: stop draining, so the request is served before the frames behind it are judged
	served  // a functional request, served on arrival: re-sample what its answer may have changed (0x28's gate)
}

// init configures the link (the flow control this side grants) and puts the server in the default
// session with a response capacity of the whole buffer. The owner then sets the server's options.
pub fn (mut c Connection) init(rx_id u32, tx_id u32, functional_id u32, bs u8, stmin u8) {
	c.rx_id = rx_id
	c.tx_id = tx_id
	c.functional_id = functional_id
	c.link.bs = bs
	c.link.stmin = stmin
	// no field defaults on Link: the N_Bs / N_Cr / WFTmax bounds are set here or a lost FC wedges it
	c.link.init_defaults()
	c.server.init(isotp.max_payload)
}

// housekeep is the top of a pass, before the owner samples its gates: ISO-TP timeouts expire (a
// stale transfer does not make the link look busy), a reset whose answer has left is applied, and
// S3 is held while the link is busy (ISO 14229-2 starts it once the exchange is over) and only then
// checked — so an expired session is back in default before any frame is judged.
pub fn (mut c Connection) housekeep(now u64) {
	c.link.tick(now)
	c.apply_answered_reset()
	if !c.link.idle() {
		c.server.hold_s3(now)
	}
	c.server.tick(now)
}

// on_frame takes one received frame. A physical frame feeds the link; a functional request is
// served at once, in bus order, so a functional 0x28 gates the very next frame of the drain.
pub fn (mut c Connection) on_frame(now u64, f &can.Frame) Rx {
	if f.ext {
		return .other
	}
	if f.id == c.rx_id {
		// only the bytes that arrived: the owner may reuse one frame, so the tail of a short one
		// holds the previous frame's bytes; a frame too short for what its PCI says is dropped
		n := if f.len > 8 { 8 } else { int(f.len) }
		if n < 1 || truncated(f.data[0], n, c.link.rx_len - c.link.rx_pos) {
			return .taken
		}
		mut p := isotp.Pdu{}
		for i in 0 .. n {
			p.data[i] = f.data[i]
		}
		c.link.on_frame(now, p)
		return if c.link.has_request() { Rx.request } else { Rx.taken }
	}
	if c.functional_id != 0 && f.id == c.functional_id {
		return c.functional(f)
	}
	return .other
}

// functional serves one functional request — a single frame (ISO 15765-2: PCI 0x0N, N = 1..7).
// Nothing queues: while the link is not quiet both ways, or a reset is pending, it is dropped, as a
// busy server does; a functional TesterPresent is periodic and simply comes again.
fn (mut c Connection) functional(f &can.Frame) Rx {
	if f.len < 2 || f.data[0] >> 4 != 0 {
		return .taken // not a single frame: nothing a functional request may be
	}
	n := int(f.data[0] & 0x0F)
	// <= 7: a CAN-FD frame may claim more
	if n < 1 || n > 7 || n >= int(f.len) || !c.link.idle() || c.server.reset_req != 0 {
		return .taken
	}
	c.refresh_dids()
	before, held := c.enter(false)
	rlen := c.server.handle_functional(&f.data[1], n, &c.resp[0])
	c.leave(before, held, false)
	c.reset_remote = false // a reset asked here is the bus's (none was pending, or this was not served)
	if rlen > 0 && !c.link.send(&c.resp[0], rlen) {
		c.cancel_reset() // never reset unanswered
	}
	// a SUPPRESSED reset (0x11 with bit 7) leaves the link idle: apply it before the next frame of
	// the drain is served under the pre-reset state
	c.apply_answered_reset()
	return .served
}

// serve dispatches the request the link reassembled. One request at a time: it is taken only once
// the previous answer has left, so a pending ECUReset always belongs to the response in flight.
// ISO-TP is half-duplex per connection, so a request that completes while an answer is still being
// sent is a tester protocol violation and is DROPPED — the tester times out and retries; nothing
// waits, so nothing can be reordered behind it.
pub fn (mut c Connection) serve() {
	got := c.link.take(&c.req[0])
	// nor once a reset is pending: the owner is about to restart, and an answer given now would
	// describe state the restart discards
	n := if c.link.busy() || c.server.reset_req != 0 { 0 } else { got }
	if n > 0 {
		c.refresh_dids()
		before, held := c.enter(false)
		rlen := c.server.handle(&c.req[0], n, &c.resp[0])
		c.leave(before, held, false)
		c.reset_remote = false
		if rlen > 0 && !c.link.send(&c.resp[0], rlen) {
			c.cancel_reset() // the answer could not be queued: never reset unanswered
		}
	}
}

// serve_remote answers a request that arrived over another transport (DoIP) on this same server,
// so both transports share one session (the unlock is per transport: enter/leave); resp holds
// isotp.max_payload. The
// answer leaves over that transport, so a reset it asks for is due only once the owner reports it
// sent (remote_sent), and is abandoned with a connection that drops first (remote_dropped). Once a
// reset is due nothing is served, as on the bus.
pub fn (mut c Connection) serve_remote(req &u8, n int, functional bool, resp &u8) int {
	if n < 1 || c.server.reset_req != 0 {
		return 0
	}
	c.refresh_dids()
	before, held := c.enter(true)
	rlen := if functional {
		c.server.handle_functional(req, n, resp)
	} else {
		c.server.handle(req, n, resp)
	}
	c.leave(before, held, true)
	// a reset waits for the transport to send what it sends — the answer, or for a suppressed one
	// its own acknowledgement (DoIP acks every diagnostic message)
	c.remote_unsent = c.server.reset_req != 0
	c.reset_remote = c.server.reset_req != 0
	return rlen
}

// remote_sent: the other transport has sent the answer serve_remote gave.
pub fn (mut c Connection) remote_sent() {
	c.remote_unsent = false
}

// remote_dropped: the other transport's connection is gone. A reset whose answer it never sent is
// abandoned; one whose answer it did send still happens (a tester disconnects right after it).
// If the session in force was entered over it, the server returns to the default session (a reset
// the bus asked for still stands), and an unlock it earned ends either way — neither outlives the
// tester that opened it. A bus tester that entered the session since keeps it; requests that
// changed nothing decide nothing.
pub fn (mut c Connection) remote_dropped() {
	if c.remote_unsent {
		c.cancel_reset()
		c.remote_unsent = false
		c.reset_remote = false
	}
	if c.remote_owns {
		c.server.end_session() // a reset the other transport asked for still happens
	}
	c.remote_owns = false
	// whoever owns the session, an unlock the dropped tester earned ends with it, and so does its
	// half-done exchange — the next connection authenticates for itself
	if c.unlock_remote {
		c.server.unlocked = 0
	}
	c.unlock_remote = false
	if c.held_back_remote {
		c.held_back = 0 // a hidden unlock of the dropped tester's is not handed back to anyone
	}
	c.sa_level[1] = 0
}

// enter: before a request over one transport — the session entry it starts in, and the unlock the OTHER
// transport holds, hidden for the request (0 = none hidden); its own exchange in progress loaded
fn (mut c Connection) enter(remote bool) (u32, u8) {
	before := c.server.session_epoch
	mut held := u8(0)
	if c.server.unlocked != 0 && c.unlock_remote != remote {
		held = c.server.unlocked
		c.server.unlocked = 0
	}
	// this transport's own exchange in progress, if its session still stands
	i := if remote { 1 } else { 0 }
	c.server.sa_level = if c.sa_epoch[i] == c.server.session_epoch { c.sa_level[i] } else { u8(0) }
	c.server.sa_seed = c.sa_seed[i]
	return before, held
}

// leave: after it. An unlock the request earned is this transport's; a hidden one comes back
// unless the request ended it for everyone (a session change relocks, as does a reset). A request
// that changed the session makes its transport the session's owner (remote_dropped).
fn (mut c Connection) leave(before u32, held u8, remote bool) {
	i := if remote { 1 } else { 0 }
	c.sa_level[i] = c.server.sa_level
	c.sa_seed[i] = c.server.sa_seed
	c.sa_epoch[i] = c.server.session_epoch
	if c.server.unlocked != 0 {
		c.unlock_remote = remote
	} else if held != 0 && c.server.session_epoch == before {
		if c.server.reset_req == 0 {
			c.server.unlocked = held
		} else {
			c.held_back = held
			c.held_back_remote = !remote
			c.held_back_epoch = c.server.session_epoch
		}
	}
	if c.server.session_epoch != before {
		c.remote_owns = remote
	}
}

// produce yields the next frame of the answer in flight, paced by the peer's flow control, for the
// owner to send. Ask only while the channel is ready: poll counts the frame as sent.
pub fn (mut c Connection) produce(now u64, mut f can.Frame) bool {
	mut p := isotp.Pdu{}
	if !c.link.poll(now, mut p) {
		return false
	}
	f.id = c.tx_id
	f.len = 8
	f.ext = false
	for i in 0 .. 8 {
		f.data[i] = p.data[i]
	}
	return true
}

// abort_tx: the channel refused a frame produce already counted as sent, so the rest of the answer
// cannot be reassembled — the transfer is abandoned (the tester retries, as on any bus error) and a
// reset whose answer was lost is never performed.
pub fn (mut c Connection) abort_tx() {
	c.link.abort_tx()
	if !c.reset_remote {
		c.cancel_reset()
	}
}

// active: an exchange is in flight or a non-default session is open — while it is, the owner keeps
// its network awake (a session must not sleep under the tester, nor an answer be stranded).
pub fn (c &Connection) active() bool {
	return !c.link.idle() || c.server.session != uds.session_default
}

// truncated: the frame (PCI byte `pci`, `n` bytes arrived) is too short for what its PCI says. A
// consecutive frame is full unless it carries the last `left` bytes of the reception; a first frame
// is always full (ISO 15765-2); a flow control needs its block size and STmin.
fn truncated(pci u8, n int, left int) bool {
	return match pci >> 4 {
		0 { int(pci & 0x0F) >= n }
		1 { n < 8 }
		2 { n < 8 && n - 1 < left }
		3 { n < 3 }
		else { false }
	}
}

// reset_due is the ECUReset kind whose answer has left the link, or the other transport that
// carried it (remote_sent), (0 = none) — for an owner that performs the reset itself
// (`owner_resets`). The link being done is not the wire being done: the
// owner still waits for its controller to transmit the answer (REQ-BOOT-012).
pub fn (c &Connection) reset_due() u8 {
	if c.server.reset_req != 0 && !c.link.busy() && !c.remote_unsent {
		return c.server.reset_req
	}
	return 0
}

// apply_answered_reset: ECUReset is two-phase — once its answer has left, the diagnostic state
// returns to power-on. An owner that resets itself does it instead (reset_due).
fn (mut c Connection) apply_answered_reset() {
	if !c.owner_resets && c.reset_due() != 0 {
		c.server.reset_state()
		c.held_back = 0
	}
}

// cancel_reset: a reset whose answer was lost does not happen — and what its request hid, the
// other transport's unlock, comes back
fn (mut c Connection) cancel_reset() {
	c.server.reset_req = 0
	if c.held_back != 0 && c.server.unlocked == 0 && c.held_back_epoch == c.server.session_epoch {
		c.server.unlocked = c.held_back
		c.unlock_remote = c.held_back_remote
	}
	c.held_back = 0
}

fn (mut c Connection) refresh_dids() {
	if c.refresh != unsafe { nil } {
		c.refresh(mut c.server)
	}
}
