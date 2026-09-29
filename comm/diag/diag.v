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
	rlen := c.server.handle_functional(&f.data[1], n, &c.resp[0])
	if rlen > 0 && !c.link.send(&c.resp[0], rlen) {
		c.server.reset_req = 0 // never reset unanswered
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
	n := if c.link.busy() { 0 } else { got }
	if n > 0 {
		c.refresh_dids()
		rlen := c.server.handle(&c.req[0], n, &c.resp[0])
		if rlen > 0 && !c.link.send(&c.resp[0], rlen) {
			c.server.reset_req = 0 // the answer could not be queued: never reset unanswered
		}
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
	c.server.reset_req = 0
}

// active: an exchange is in flight or a non-default session is open — while it is, the owner keeps
// its network awake (a session must not sleep under the tester, nor an answer be stranded).
pub fn (c Connection) active() bool {
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

// reset_due is the ECUReset kind whose answer has left the link (0 = none) — for an owner that
// performs the reset itself (`owner_resets`). The link being done is not the wire being done: the
// owner still waits for its controller to transmit the answer (REQ-BOOT-012).
pub fn (c Connection) reset_due() u8 {
	if c.server.reset_req != 0 && !c.link.busy() {
		return c.server.reset_req
	}
	return 0
}

// apply_answered_reset: ECUReset is two-phase — once its answer has left, the diagnostic state
// returns to power-on. An owner that resets itself does it instead (reset_due).
fn (mut c Connection) apply_answered_reset() {
	if !c.owner_resets && c.server.reset_req != 0 && !c.link.busy() {
		c.server.reset_state()
	}
}

fn (mut c Connection) refresh_dids() {
	if c.refresh != unsafe { nil } {
		c.refresh(mut c.server)
	}
}
