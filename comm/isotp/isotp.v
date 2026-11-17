module isotp

// ISO-TP (ISO 15765-2) segmentation/reassembly, no-alloc and transport-agnostic:
// a Link works on bare PDUs of up to 64 bytes (one CAN or CAN-FD frame's worth, each carrying its
// length) and knows nothing about CAN ids or the driver — the bridge filters by rx_id and stamps
// tx_id, so this module stays above the driver-port boundary like the rest of comm/.
//
// One Link is a half-duplex diagnostic connection: it reassembles messages from
// incoming PDUs and segments an outgoing message. Poll-based to fit the bridge tick:
//   * on_frame(now, pdu) — feed a received PDU
//   * poll(now, mut out) — drain the next PDU to send (FC / SF / FF / CF)
//   * take(dst)          — copy out a fully reassembled message (0 if none)
//   * send(src, len)     — start transmitting a message
//
// PDU types (N_PCI high nibble of byte 0):
//   0x0 SF single   0x1 FF first   0x2 CF consecutive   0x3 FC flow-control
//
// Frame length: a Link transmits with its TX_DL (`tx_dl`: 8, or a CAN-FD length up to 64 on a
// CAN-FD bus) and receives any length without a setting — a reception's RX_DL is its first frame's
// length (ISO 15765-2:2016). Flow control frames are always 8 bytes.

// A Link holds no message storage of its own: its owner gives it a receive buffer and a transmit
// buffer (bind_rx / bind_tx) and their capacities, which are the longest message the link takes in
// and sends. So each connection pays for the maximum it is configured with — a node's diagnostic
// connection its [isotp] max_message, the shell and the trace their own fixed message — and none
// pays for another's. An unbound link fails closed: it sends nothing and refuses every first frame.

// min_message is the shortest maximum a node's diagnostic connection may be configured with: a
// first frame needs at least 8 bytes behind it, and every service the server answers in one frame
// (0x10, 0x27, 0x3E and their refusals) fits.
pub const min_message = 8

// default_message is a diagnostic connection's maximum message length when its node does not
// configure one ([isotp] max_message): what every link had before it became configurable.
pub const default_message = 520

// message_limit is the longest message a link takes: the longest length a first frame's 12-bit
// FF_DL states. The escape first frame (FF_DL 0 and a 32-bit length) is not supported and stays
// refused with FC.OVFLW (REQ-CAN-TP-015), so no capacity above this is ever used.
pub const message_limit = 4095

// Pdu is one CAN or CAN-FD frame's worth of ISO-TP bytes: `len` of the 64 are the frame (CAN_DL). A
// len of 0 reads as 8, so a Pdu built by hand is a classic frame. No id: the bridge owns the rx/tx
// addressing.
pub struct Pdu {
pub mut:
	data [64]u8
	len  int
}

// dl: the frame's length, a len of 0 read as 8
fn (p &Pdu) dl() int {
	return if p.len == 0 { 8 } else { p.len }
}

// valid_dl: `dl` is a frame length ISO-TP may transmit with (TX_DL) and a reception may run at
// (RX_DL): 8, or a longer length a CAN-FD DLC expresses.
pub fn valid_dl(dl int) bool {
	return match dl {
		8, 12, 16, 20, 24, 32, 48, 64 { true }
		else { false }
	}
}

// sf_max is the longest message a single frame carries in a frame of `dl` bytes: 7 behind the
// 4-bit length of a frame of up to 8 bytes, dl - 2 behind the escape of a longer CAN-FD one.
pub fn sf_max(dl int) int {
	return if dl <= 8 { 7 } else { dl - 2 }
}

// frame_len_ok: a received frame of `n` bytes is one a controller delivers — 1 to 8, or a CAN-FD
// length. Every decoder below asks it first, so no caller reads past what such a frame holds.
fn frame_len_ok(n int) bool {
	return n >= 1 && (n <= 8 || valid_dl(n))
}

// fd_padded: the length a frame carrying `n` bytes goes out at — 8, or past 8 the next length a
// CAN-FD DLC expresses (12, 16, 20, 24, 32, 48, 64)
fn fd_padded(n int) int {
	return if n <= 8 {
		8
	} else if n <= 12 {
		12
	} else if n <= 16 {
		16
	} else if n <= 20 {
		20
	} else if n <= 24 {
		24
	} else if n <= 32 {
		32
	} else if n <= 48 {
		48
	} else {
		64
	}
}

// single_frame decodes a received single frame of `n` bytes at `data`: where its message starts
// and how long it is, the length 0 meaning the frame is not a valid single frame. In a frame of up
// to 8 bytes the length is the first byte's low nibble, 1..7; in a longer (CAN-FD) one the first
// byte is 0x00, the escape, and the length the second byte, 1 up to the frame's length less 2. A
// classic single frame in a frame longer than 8 bytes is not a single frame (ISO 15765-2:2016;
// blobly_net's software ISO-TP and the Linux kernel's decide alike). Nor is a frame of a length no
// CAN-FD frame has (9..11, 13..15, ...): that rule is this link's own (frame_len_ok) — blobly_net's
// single_frame and the kernel's take such a frame when it holds its length, though no controller
// delivers one. The physical request id (on_frame) and the functional one (comm/diag) both ask it,
// so the two cannot disagree about a frame; the caller bounds the length by its own capacity.
pub fn single_frame(data &u8, n int) (int, int) {
	if !frame_len_ok(n) {
		return 0, 0
	}
	b0 := unsafe { data[0] }
	if b0 >> 4 != 0 {
		return 0, 0
	}
	if n > 8 {
		len := int(unsafe { data[1] })
		if b0 != 0 || len < 1 || len > n - 2 {
			return 0, 0
		}
		return 2, len
	}
	len := int(b0 & 0x0F)
	if len < 1 || len > 7 || 1 + len > n {
		return 0, 0
	}
	return 1, len
}

// FfVerdict is what a received first frame gets: ignored (no flow control), refused with FC.OVFLW,
// or accepted (a reception starts, a CTS is owed)
enum FfVerdict {
	ignore
	overflow
	accept
}

enum RxPhase {
	idle
	receiving
}

enum TxPhase {
	idle
	send_sf
	send_ff
	wait_fc
	send_cf
}

pub struct Link {
pub mut:
	bs    u8 // BlockSize we grant in our FC (0 = whole message at once)
	stmin u8 // STmin we ask of the sender (ms)
	// TX_DL: the frame length this link transmits with — 8, or a CAN-FD length up to 64 (valid_dl)
	// that only an owner whose channel is opened CAN-FD may set; 0 or any other value reads as 8.
	// send() takes it for the whole message, so a change never alters a transfer in flight. No
	// field default (the _vinit rule): a zeroed link transmits classic frames.
	tx_dl u8
	// N_Bs: max time to wait for a flow-control frame before aborting the tx. A lost
	// or never-sent FC must not wedge the link busy forever (ISO 15765-2 N_Bs).
	// 0 disables the timeout (wait indefinitely). NO field default: a __global's
	// field initializers land in _vinit, which freestanding never runs — the
	// target read 0 = disabled and the shell wedged on one unanswered FF (the
	// H755 bench, 4th _vinit sighting). Call init_defaults() instead.
	n_bs_us u64
	// WFTmax: how many consecutive FC.WAIT frames to tolerate before aborting. Each WAIT
	// legitimately restarts N_Bs, so without a bound an endless-WAIT peer would re-wedge
	// the link the N_Bs timeout exists to protect. 0 disables the WAIT bound.
	// No field default — same _vinit rule as n_bs_us.
	wft_max u8
	// transmissions the link gave up on (no flow control within N_Bs, too many WAITs, an overflow
	// or an undefined flow status)
	// — counted, so an owner tells a send that failed from one that completed, both of which leave
	// the link not busy. Zero from the zeroed struct (no default: the _vinit rule).
	tx_aborts u32
	// frames the link took: a single frame, a first frame or a consecutive frame in sequence of a
	// reception, a flow control its transmission was waiting for (CTS, or a WAIT within WFTmax) —
	// not what it ignored or rejected: an owner bounding a stalled exchange by "no progress" reads
	// progress here, not from what merely arrived
	progress u32
	// N_Cr: max gap between consecutive frames of an in-flight RECEIVE before the
	// partial reassembly is abandoned (ISO 15765-2 N_Cr) — without it a sender that
	// dies after its FF leaves the link .receiving forever (REQ-CAN-TP-007/008 bound BOTH
	// directions; the gap was documented in move-data.md and is now closed).
	// 0 disables. No field default — the _vinit rule again: init_defaults() sets it.
	n_cr_us u64
	// N_Ar: max time a flow control we owe (a CTS, or an OVFLW) may wait to be handed to the
	// controller — a transmit FIFO that never drains (bus-off, nobody acknowledging) — before the
	// reception it belongs to is abandoned (ISO 15765-2 N_Ar, REQ-CAN-TP-029). Measured from when
	// the flow control first became owed; a repeated first frame does not restart it. 0 disables.
	// No field default — init_defaults() sets it.
	n_ar_us u64
	// receptions the link abandoned because a timer ran out (N_Cr, N_Ar) — counted, so an owner
	// bounding an exchange tells a reception given up from one still running. An owner's own
	// abort_rx is not counted. Zero from the zeroed struct.
	rx_aborts u32
	// reassembly (rx): rx_buf holds rx_cap bytes, the owner's (bind_rx). The nil default is a zero
	// value, so it is no _vinit initializer: an unbound link has rx_cap 0 and takes nothing.
	rx        RxPhase
	rx_buf    &u8 = unsafe { nil }
	rx_cap    int
	rx_len    int
	rx_pos    int
	rx_dl     int // the reception's RX_DL: its first frame's length, every CF but the last as long
	rx_sn     u8
	rx_count  u8 // CFs since our last FC
	fc_send   bool
	fc_ovflw  bool // an FC.OVFLW is owed: a first frame announced more than rx_cap
	ready     bool
	ready_len int
	// segmentation (tx): tx_buf holds tx_cap bytes, the owner's (bind_tx)
	tx         TxPhase
	tx_buf     &u8 = unsafe { nil }
	tx_cap     int
	tx_len     int
	tx_pos     int
	tx_fl      int // the frame length of the transmission in flight: tx_dl as send() found it
	tx_sn      u8
	peer_bs    u8  // BlockSize the receiver granted (0 = unlimited)
	peer_stmin u64 // STmin the receiver asked (us)
	block_left  u8
	next_us     u64 // earliest time to send the next CF
	fc_deadline u64 // abort the tx if still in wait_fc past this (N_Bs); set on entry
	rx_deadline u64 // abort the rx if no CF arrived by this (N_Cr); set on FF, refreshed per CF
	ar_deadline u64 // abandon the rx if the flow control owed has not gone by this (N_Ar); 0 = none owed
	wft_count   u8  // consecutive FC.WAIT frames seen for the current block (vs wft_max)
}

// dl: the link's TX_DL — tx_dl when it is a length ISO-TP transmits with, else 8
fn (l &Link) dl() int {
	return if valid_dl(int(l.tx_dl)) { int(l.tx_dl) } else { 8 }
}

// bind_rx gives the link its receive buffer: `cap` bytes at `buf`, the longest message it takes
// in (clamped to message_limit; a nil buffer is capacity 0). A reception in progress, and a message
// not yet taken, are abandoned — they were in the old buffer. An owner may hand the same buffer to
// take() as dst: a message is then read where it was reassembled.
pub fn (mut l Link) bind_rx(buf &u8, cap int) {
	l.abort_rx()
	l.rx_buf = buf
	l.rx_cap = bounded_cap(buf, cap)
}

// bind_tx gives the link its transmit buffer: `cap` bytes at `buf`, the longest message it sends
// (clamped to message_limit; a nil buffer is capacity 0). Refused while a transmission is in
// flight, whose bytes are still read from the old buffer.
pub fn (mut l Link) bind_tx(buf &u8, cap int) bool {
	if l.tx != .idle {
		return false
	}
	l.tx_buf = buf
	l.tx_cap = bounded_cap(buf, cap)
	return true
}

fn bounded_cap(buf &u8, cap int) int {
	if buf == unsafe { nil } || cap <= 0 {
		return 0
	}
	return if cap > message_limit { message_limit } else { cap }
}

// send starts transmitting `len` bytes from `src`, copied into the transmit buffer, so `src` may be
// reused at once — unless it IS the transmit buffer, which then holds the message until the link
// is idle again. Refused if a tx is already in flight or the message exceeds the transmit
// capacity (REQ-CAN-TP-014). A message of up to sf_max(TX_DL) bytes goes as a single frame, a
// longer one as a first frame and consecutive frames (REQ-CAN-TP-027).
pub fn (mut l Link) send(src &u8, len int) bool {
	if l.tx != .idle || len <= 0 || len > l.tx_cap {
		return false
	}
	if src != l.tx_buf {
		unsafe {
			for i in 0 .. len {
				l.tx_buf[i] = src[i]
			}
		}
	}
	l.tx_len = len
	l.tx_pos = 0
	l.tx_sn = 1
	l.wft_count = 0
	l.tx_fl = l.dl() // the frame length for the whole message, whatever tx_dl becomes meanwhile
	l.tx = if len <= sf_max(l.tx_fl) { TxPhase.send_sf } else { TxPhase.send_ff }
	return true
}

// busy reports whether a tx is in flight (segmenting or awaiting flow control), so a
// caller serialising several messages on one Link starts the next only when it's free.
pub fn (l &Link) busy() bool {
	return l.tx != .idle
}

// abort_tx abandons the transmission in flight — for an owner whose channel refused a frame the
// link had already counted as sent: continuing would send the rest of a message the receiver can
// no longer reassemble, and retrying the refused frame later could land after N_Bs expired.
pub fn (mut l Link) abort_tx() {
	l.tx = .idle
}

// give_up_tx: the link abandons its transmission (a transport failure, counted in tx_aborts)
fn (mut l Link) give_up_tx() {
	l.tx = .idle
	l.tx_aborts++
}

// abort_rx abandons the reception in progress and a completed message not yet taken, and owes no
// flow control — for an owner that is done with the exchange they belonged to (a gateway's
// routed request superseded by the tester's next one).
pub fn (mut l Link) abort_rx() {
	l.fc_ovflw = false
	l.end_rx()
	l.ready = false
}

// end_rx: the reception in progress is over, and no CTS is owed for it (nor N_Ar armed, unless an
// OVFLW is still owed)
fn (mut l Link) end_rx() {
	l.rx = .idle
	l.fc_send = false
	if !l.fc_ovflw {
		l.ar_deadline = 0
	}
}

// owe: a flow control is about to become owed at `now` — N_Ar runs from here, unless one is owed
// already: a repeated first frame, or one replacing a reception whose CTS has not gone, is the
// same pending flow control and keeps the earlier deadline (REQ-CAN-TP-029). Call before setting
// fc_send / fc_ovflw.
fn (mut l Link) owe(now u64) {
	if !(l.fc_send || l.fc_ovflw) {
		l.ar_deadline = now + l.n_ar_us
	}
}

// idle reports that nothing is in flight in EITHER direction: no tx segmenting or awaiting flow
// control, no multi-frame reception in progress or flow control owed, and no completed message
// waiting to be taken. A caller that interleaves a second kind of traffic on the link (functional
// requests answered on the physical id) starts only when the physical exchange is fully quiet.
pub fn (l &Link) idle() bool {
	return l.tx == .idle && l.rx != .receiving && !l.fc_send && !l.fc_ovflw && !l.ready
}

// has_request reports that a completed message is waiting to be taken.
pub fn (l &Link) has_request() bool {
	return l.ready
}

// take copies a completed message to `dst` and returns its length (0 if none). `dst` holds rx_cap
// bytes, or is the receive buffer itself.
pub fn (mut l Link) take(dst &u8) int {
	if !l.ready {
		return 0
	}
	n := l.ready_len
	if dst != l.rx_buf {
		unsafe {
			for i in 0 .. n {
				dst[i] = l.rx_buf[i]
			}
		}
	}
	l.ready = false
	return n
}

// ff_verdict judges a received first frame (PCI type 1) at the frame's length, its RX_DL: one of 8
// bytes or a CAN-FD length, else ignored as a frame too short for its PCI or of a length no CAN-FD
// frame has. The escape first frame (FF_DL 0, a 32-bit length) is refused with FC.OVFLW whatever
// length it states (REQ-CAN-TP-015: no capacity reaches past 4095 — ISO 15765-2:2016 and blobly_net
// ignore one stating 4095 or less instead); a length that fits a single frame of the same RX_DL is
// ignored, as a message that must have been sent as one (REQ-CAN-TP-028); a length past the receive
// buffer is refused with FC.OVFLW (REQ-CAN-TP-014/015).
fn (l &Link) ff_verdict(p &Pdu) FfVerdict {
	n := p.dl()
	if n < 8 || !frame_len_ok(n) {
		return .ignore
	}
	total := int((u32(p.data[0] & 0x0F) << 8) | u32(p.data[1]))
	if total == 0 {
		return .overflow
	}
	if total <= sf_max(n) {
		return .ignore
	}
	if total > l.rx_cap {
		return .overflow
	}
	return .accept
}

// overflows: `p` is a first frame the link refuses with FC.OVFLW (ff_verdict) — for an owner that
// answers for that refusal itself (a DoIP gateway, comm/diagroute).
pub fn (l &Link) overflows(p &Pdu) bool {
	return p.data[0] >> 4 == 1 && l.ff_verdict(p) == .overflow
}

// misfit: a received consecutive frame or flow control whose length its PCI and the reception do
// not allow — read nothing of it (REQ-CAN-TP-013, REQ-CAN-TP-028). A length no controller delivers;
// a consecutive frame longer than the reception's RX_DL, or shorter while it does not carry all
// that is left of the message (only the last may be short: its padding off); a flow control
// shorter than its FS, BS and STmin. A consecutive frame of the wrong length is ignored and the
// reception kept, as the Linux kernel's isotp does (blobly_net aborts instead; on the wire both
// end alike, since the sender's next frame then carries the following sequence number).
fn (l &Link) misfit(p &Pdu) bool {
	n := p.dl()
	if !frame_len_ok(n) {
		return true
	}
	return match p.data[0] >> 4 {
		2 { n > l.rx_dl || (n < l.rx_dl && n - 1 < l.rx_len - l.rx_pos) }
		3 { n < 3 }
		else { false }
	}
}

// on_flow_control feeds a link that only transmits — the shell's response stream, the trace's
// dump — one frame received on its flow-control id (`n` bytes at `data`): only a flow control
// (PCI type 3, whole enough to read FS, BS and STmin) reaches it. Anything else there, a first
// frame above all, is dropped rather than start a reception whose flow control would go out
// inside the stream (REQ-CAN-TP-024). True when the frame was taken in.
pub fn (mut l Link) on_flow_control(now u64, data &u8, n int) bool {
	if n < 1 || n > 64 || unsafe { data[0] } >> 4 != 3 {
		return false
	}
	mut p := Pdu{
		len: n
	}
	for i in 0 .. p.len {
		p.data[i] = unsafe { data[i] }
	}
	if l.misfit(&p) {
		return false
	}
	l.on_frame(now, p)
	return true
}

// on_frame feeds a received PDU (the bridge passes only rx_id frames), of `p.len` bytes: only those
// are read, and a frame too short for its PCI, or of a length its reception does not allow, is
// ignored (single_frame, ff_verdict, misfit).
pub fn (mut l Link) on_frame(now u64, p Pdu) {
	n := p.dl()
	pci := p.data[0] & 0xF0
	low := p.data[0] & 0x0F
	match pci {
		0x00 { // single frame: classic, or behind the CAN-FD escape (REQ-CAN-TP-003, -028)
			at, sn := single_frame(&p.data[0], n)
			if sn > 0 && sn <= l.rx_cap {
				for i in 0 .. sn {
					unsafe {
						l.rx_buf[i] = p.data[at + i]
					}
				}
				l.ready = true
				l.ready_len = sn
				// a reception it interrupts is over (REQ-CAN-TP-012), and so is its CTS — and a
				// refusal still owed for an earlier first frame
				l.fc_ovflw = false
				l.end_rx()
				l.progress++
			}
		}
		0x10 { // first frame
			match l.ff_verdict(&p) {
				.accept {
					total := int((u32(low) << 8) | u32(p.data[1]))
					// N_Ar runs from the first flow control owed: one still owed for the reception
					// this restarts, or an OVFLW still owed, keeps its deadline
					l.owe(now)
					l.fc_ovflw = false // a refusal owed for an earlier first frame is moot now
					// a first frame that replaces a reception in progress restarts it, and moves
					// nothing: a sender repeating its first frame is not a transfer advancing
					fresh := l.rx != .receiving
					head := n - 2 // RX_DL - 2 bytes of the message ride in the first frame
					for i in 0 .. head {
						unsafe {
							l.rx_buf[i] = p.data[2 + i]
						}
					}
					l.rx_len = total
					l.rx_pos = head
					l.rx_dl = n // the reception's RX_DL: every CF but the last as long
					l.rx_sn = 1
					l.rx_count = 0
					l.rx = .receiving
					l.rx_deadline = 0 // unarm: a stale deadline from a PRIOR transfer would let
					// tick() abort this fresh receive before its CTS ever goes out (codex #218)
					l.fc_send = true // answer with FC (CTS); N_Cr is armed when the CTS is
					// actually emitted (poll), not here — a backpressured bridge may hold the
					// CTS for a while and the sender is correctly waiting for it
					if fresh {
						l.progress++
					}
				}
				.overflow {
					// more than we can hold (the escape first frame always is, above
					// message_limit): refuse it at once with FC.OVFLW, so the sender fails now
					// rather than waiting out its N_Bs (REQ-CAN-TP-015); like any first frame it
					// ends a reception in progress (REQ-CAN-TP-012). A flow control owed already
					// keeps its N_Ar deadline
					l.owe(now)
					l.fc_ovflw = true
					l.end_rx()
				}
				.ignore {}
			}
		}
		0x20 { // consecutive frame
			if l.misfit(&p) {
				return // the wrong length: nothing of it read, the reception kept (REQ-CAN-TP-028)
			}
			if l.rx == .receiving && l.n_cr_us != 0 && l.rx_deadline != 0 && now >= l.rx_deadline {
				// N_Cr expired: the transfer is dead — a late CF must not resurrect it, and no
				// stale CTS is owed for it (codex #218)
				l.end_rx()
				l.rx_aborts++
			}
			if l.rx == .receiving && low == (l.rx_sn & 0x0F) {
				l.rx_deadline = now + l.n_cr_us // progress: the N_Cr window restarts per CF
				mut m := l.rx_len - l.rx_pos
				if m > n - 1 {
					m = n - 1
				}
				for i in 0 .. m {
					unsafe {
						l.rx_buf[l.rx_pos + i] = p.data[1 + i]
					}
				}
				l.rx_pos += m
				l.rx_sn = (l.rx_sn + 1) & 0x0F
				l.rx_count++
				// progress only once our flow control has gone: a sender running ahead of it (and
				// restarting with a first frame) advances nothing an owner's stall bound should see
				if !l.fc_send {
					l.progress++
				}
				if l.rx_pos >= l.rx_len {
					l.ready = true
					l.ready_len = l.rx_len
					l.rx = .idle
				} else if l.bs != 0 && l.rx_count >= l.bs {
					l.rx_count = 0
					l.rx_deadline = 0 // block full: the sender now waits for the next CTS, so
					// unarm N_Cr — it re-arms when poll() emits that CTS, not before (codex #218)
					l.owe(now)
					l.fc_send = true
				}
			} else if l.rx == .receiving {
				l.end_rx() // sequence error -> abort, and no CTS owed for it
			}
		}
		0x30 { // flow control (for our tx)
			if l.misfit(&p) {
				return // too short for FS, BS and STmin
			}
			if l.tx == .wait_fc {
				// A FC that arrives after N_Bs has already elapsed is too late: the transfer
				// has timed out. Abort rather than resurrect it — a caller that processes rx
				// before polling could otherwise let a late WAIT/CTS extend a dead transfer
				// past the deadline poll() would have aborted at.
				if l.n_bs_us != 0 && now >= l.fc_deadline {
					l.give_up_tx()
					return
				}
				fs := low
				if fs == 0 { // CTS
					l.peer_bs = p.data[1]
					l.peer_stmin = decode_stmin(p.data[2])
					l.block_left = l.peer_bs
					l.next_us = now
					l.wft_count = 0
					l.tx = .send_cf
					l.fc_deadline = now + l.n_bs_us // stall bound for the CF burst (refreshed per CF)
					l.progress++
				} else if fs == 1 { // WAIT: peer not ready — restart N_Bs, but bound the WAITs
					// check before incrementing so wft_count never exceeds wft_max (<=255) and
					// can't wrap back to 0 (which would let an endless-WAIT peer wedge the link).
					if l.wft_max != 0 && l.wft_count >= l.wft_max {
						l.give_up_tx() // too many WAITs -> give up rather than wait forever
					} else {
						l.wft_count++
						l.fc_deadline = now + l.n_bs_us
						l.progress++
					}
				} else { // OVFLW, or a flow status the standard does not define -> abort (REQ-CAN-TP-010)
					l.give_up_tx()
				}
			}
		}
		else {}
	}
}

// init_defaults sets the protocol timeouts every embedded consumer must run with
// (N_Bs, N_Cr and N_Ar 1 s, WFTmax 16 — the standard's timeout values). Field defaults can't do
// this job: on a freestanding target a __global's initializers live in the never-called _vinit, so
// every module init path calls this explicitly (the build lint enforces the class).
pub fn (mut l Link) init_defaults() {
	l.n_bs_us = 1_000_000
	l.wft_max = 16
	l.n_cr_us = 1_000_000
	l.n_ar_us = 1_000_000
}

// tick advances the link's time-based state independently of poll(): the N_Bs flow-control
// timeout, and N_Cr and N_Ar on a reception. A caller that gates poll() on Tx-FIFO space
// (`for tx_ready() && poll(...)`) must call tick() every cycle so a full FIFO can't wedge the link
// forever — otherwise a dump on a down/quiet bus (FF sent, no FC, FIFO stays full) never reaches
// its abort deadline, and a flow control that cannot leave never reaches N_Ar.
pub fn (mut l Link) tick(now u64) {
	// Abort a tx that made no progress within its deadline — in wait_fc (no flow control) OR in
	// send_cf (CTS received, but backpressure kept the FIFO full so no CF went out). fc_deadline
	// is set on entering either state and refreshed on each CF sent.
	if l.n_bs_us != 0 && (l.tx == .wait_fc || l.tx == .send_cf) && now >= l.fc_deadline {
		l.give_up_tx()
	}
	// N_Ar: a flow control we owe that the controller never took (a transmit FIFO that stays full)
	// abandons the reception it belongs to, so the link goes idle — S3 runs again and functional
	// requests are served (REQ-CAN-TP-029)
	if l.n_ar_us != 0 && l.ar_deadline != 0 && now >= l.ar_deadline && (l.fc_send || l.fc_ovflw) {
		l.fc_ovflw = false
		l.end_rx()
		l.rx_aborts++
	}
	// N_Cr: a receive whose sender went quiet mid-transfer is abandoned, so the link
	// (and its reassembly buffer) cannot stay .receiving forever (REQ-CAN-TP-008). Only
	// armed deadlines count — rx_deadline == 0 means the CTS hasn't been emitted yet,
	// so the sender is correctly waiting for flow control, not stalling (codex #218).
	if l.n_cr_us != 0 && l.rx == .receiving && l.rx_deadline != 0 && now >= l.rx_deadline {
		l.end_rx() // and no stale CTS for an abandoned transfer (codex #218)
		l.rx_aborts++
	}
}

// poll produces the next PDU to send, if any (FC has priority, then the tx FSM), its length in
// out.len: a flow control 8 bytes; a single, first or consecutive frame at most the TX_DL send()
// took, padded with 0x00 to 8 or past 8 to the next CAN-FD length (REQ-CAN-TP-027).
pub fn (mut l Link) poll(now u64, mut out Pdu) bool {
	if l.fc_ovflw {
		zero(mut out, 8)
		out.data[0] = 0x32 // FC, OVFLW
		l.fc_ovflw = false
		l.ar_deadline = 0 // handed over: N_Ar met
		return true
	}
	if l.fc_send {
		zero(mut out, 8)
		out.data[0] = 0x30 // FC, CTS
		out.data[1] = l.bs
		out.data[2] = l.stmin
		l.fc_send = false
		l.ar_deadline = 0 // handed over: N_Ar met
		// N_Cr starts NOW: the sender only sends CFs after it sees this CTS, so the
		// receive deadline must be measured from CTS emission, not FF reception — both
		// the initial FF and every block boundary (codex #218)
		l.rx_deadline = now + l.n_cr_us
		return true
	}
	match l.tx {
		.send_sf {
			if l.tx_len <= 7 {
				zero(mut out, 8)
				out.data[0] = 0x00 | u8(l.tx_len)
				for i in 0 .. l.tx_len {
					out.data[1 + i] = unsafe { l.tx_buf[i] }
				}
			} else {
				// behind the CAN-FD escape: 0x00, then the length (only with a TX_DL above 8)
				zero(mut out, fd_padded(2 + l.tx_len))
				out.data[1] = u8(l.tx_len)
				for i in 0 .. l.tx_len {
					out.data[2 + i] = unsafe { l.tx_buf[i] }
				}
			}
			l.tx = .idle
			return true
		}
		.send_ff {
			// a first frame of TX_DL bytes, TX_DL - 2 of them the message
			zero(mut out, l.tx_fl)
			out.data[0] = 0x10 | u8((u32(l.tx_len) >> 8) & 0x0F)
			out.data[1] = u8(l.tx_len & 0xFF)
			head := l.tx_fl - 2
			for i in 0 .. head {
				out.data[2 + i] = unsafe { l.tx_buf[i] }
			}
			l.tx_pos = head
			l.tx_sn = 1
			l.tx = .wait_fc
			l.fc_deadline = now + l.n_bs_us
			return true
		}
		.wait_fc {
			// N_Bs: a missed or never-sent FC (e.g. a dump issued before a receiver is
			// bound) must not leave the link busy forever — abort so the next dump is free.
			if l.n_bs_us != 0 && now >= l.fc_deadline {
				l.give_up_tx()
			}
			return false
		}
		.send_cf {
			if now < l.next_us {
				return false
			}
			// TX_DL - 1 bytes of the message each, the last only what is left
			mut m := l.tx_len - l.tx_pos
			if m > l.tx_fl - 1 {
				m = l.tx_fl - 1
			}
			zero(mut out, fd_padded(1 + m))
			out.data[0] = 0x20 | (l.tx_sn & 0x0F)
			for i in 0 .. m {
				out.data[1 + i] = unsafe { l.tx_buf[l.tx_pos + i] }
			}
			l.tx_pos += m
			l.tx_sn = (l.tx_sn + 1) & 0x0F
			l.next_us = now + l.peer_stmin
			l.fc_deadline = now + l.n_bs_us // progress made -> refresh the send_cf stall bound
			if l.tx_pos >= l.tx_len {
				l.tx = .idle
			} else if l.peer_bs != 0 {
				l.block_left--
				if l.block_left == 0 {
					l.tx = .wait_fc
					l.fc_deadline = now + l.n_bs_us
				}
			}
			return true
		}
		else {
			return false
		}
	}
}

// zero starts a PDU of `n` bytes: its length, every byte the fill byte (0x00)
fn zero(mut p Pdu, n int) {
	for i in 0 .. n {
		p.data[i] = 0
	}
	p.len = n
}

// decode_stmin maps the FC STmin byte to microseconds: 0x00-0x7F ms, 0xF1-0xF9
// = 100-900 us; a reserved value (0x80-0xF0, 0xFA-0xFF) as 0x7F, the longest (REQ-CAN-TP-006).
fn decode_stmin(b u8) u64 {
	if b <= 0x7F {
		return u64(b) * 1000
	}
	if b >= 0xF1 && b <= 0xF9 {
		return u64(b - 0xF0) * 100
	}
	return 127_000
}
