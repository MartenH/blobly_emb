module isotp

// ISO-TP (ISO 15765-2) segmentation/reassembly, no-alloc and transport-agnostic:
// a Link works on bare 8-byte PDUs (one CAN frame's worth) and knows nothing about
// CAN ids or the driver — the bridge filters by rx_id and stamps tx_id, so this
// module stays above the driver-port boundary like the rest of comm/.
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

// max_payload bounds one reassembled message — fixes the per-Link buffer size.
// (ISO-TP allows 4095; we cap lower for an embedded, no-alloc footprint.) Sized to hold the
// largest message the system sends: one trace dump block = an 8-byte self-describing block
// header + a full 64-record ring (64 x 8) = 520 bytes (see comm/trace.pack_block + the
// multi-core dump owner). buffer_records is bounded to 64 so a block always fits one payload.
pub const max_payload = 520

// Pdu is one CAN frame's worth of ISO-TP bytes (always 8, padded). No id: the
// bridge owns the rx/tx addressing.
pub struct Pdu {
pub mut:
	data [8]u8
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
	// N_Bs: max time to wait for a flow-control frame before aborting the tx. A lost
	// or never-sent FC must not wedge the link busy forever (ISO 15765-2 N_Bs;
	// default 1 s). 0 disables the timeout (wait indefinitely).
	n_bs_us u64 = 1_000_000
	// WFTmax: how many consecutive FC.WAIT frames to tolerate before aborting. Each WAIT
	// legitimately restarts N_Bs, so without a bound an endless-WAIT peer would re-wedge
	// the link the N_Bs timeout exists to protect. 0 disables the WAIT bound.
	wft_max u8 = 16
	// reassembly (rx)
	rx        RxPhase
	rx_buf    [max_payload]u8
	rx_len    int
	rx_pos    int
	rx_sn     u8
	rx_count  u8 // CFs since our last FC
	fc_send   bool
	ready     bool
	ready_len int
	// segmentation (tx)
	tx         TxPhase
	tx_buf     [max_payload]u8
	tx_len     int
	tx_pos     int
	tx_sn      u8
	peer_bs    u8  // BlockSize the receiver granted (0 = unlimited)
	peer_stmin u64 // STmin the receiver asked (us)
	block_left  u8
	next_us     u64 // earliest time to send the next CF
	fc_deadline u64 // abort the tx if still in wait_fc past this (N_Bs); set on entry
	wft_count   u8  // consecutive FC.WAIT frames seen for the current block (vs wft_max)
}

// send starts transmitting `len` bytes from `src`. Drops the message if a tx is
// already in flight or it exceeds max_payload.
pub fn (mut l Link) send(src &u8, len int) bool {
	if l.tx != .idle || len <= 0 || len > max_payload {
		return false
	}
	unsafe {
		for i in 0 .. len {
			l.tx_buf[i] = src[i]
		}
	}
	l.tx_len = len
	l.tx_pos = 0
	l.tx_sn = 1
	l.wft_count = 0
	l.tx = if len <= 7 { TxPhase.send_sf } else { TxPhase.send_ff }
	return true
}

// busy reports whether a tx is in flight (segmenting or awaiting flow control), so a
// caller serialising several messages on one Link starts the next only when it's free.
pub fn (l Link) busy() bool {
	return l.tx != .idle
}

// take copies a completed message to `dst` and returns its length (0 if none).
pub fn (mut l Link) take(dst &u8) int {
	if !l.ready {
		return 0
	}
	n := l.ready_len
	unsafe {
		for i in 0 .. n {
			dst[i] = l.rx_buf[i]
		}
	}
	l.ready = false
	return n
}

// on_frame feeds a received PDU (the bridge passes only rx_id frames).
pub fn (mut l Link) on_frame(now u64, p Pdu) {
	pci := p.data[0] & 0xF0
	low := p.data[0] & 0x0F
	match pci {
		0x00 { // single frame
			n := int(low)
			if n > 0 && n <= 7 {
				for i in 0 .. n {
					l.rx_buf[i] = p.data[1 + i]
				}
				l.ready = true
				l.ready_len = n
				l.rx = .idle
			}
		}
		0x10 { // first frame
			total := int((u32(low) << 8) | u32(p.data[1]))
			if total > 7 && total <= max_payload {
				for i in 0 .. 6 {
					l.rx_buf[i] = p.data[2 + i]
				}
				l.rx_len = total
				l.rx_pos = 6
				l.rx_sn = 1
				l.rx_count = 0
				l.rx = .receiving
				l.fc_send = true // answer with FC (CTS)
			}
		}
		0x20 { // consecutive frame
			if l.rx == .receiving && low == (l.rx_sn & 0x0F) {
				mut n := l.rx_len - l.rx_pos
				if n > 7 {
					n = 7
				}
				for i in 0 .. n {
					l.rx_buf[l.rx_pos + i] = p.data[1 + i]
				}
				l.rx_pos += n
				l.rx_sn = (l.rx_sn + 1) & 0x0F
				l.rx_count++
				if l.rx_pos >= l.rx_len {
					l.ready = true
					l.ready_len = l.rx_len
					l.rx = .idle
				} else if l.bs != 0 && l.rx_count >= l.bs {
					l.rx_count = 0
					l.fc_send = true
				}
			} else if l.rx == .receiving {
				l.rx = .idle // sequence error -> abort
			}
		}
		0x30 { // flow control (for our tx)
			if l.tx == .wait_fc {
				// A FC that arrives after N_Bs has already elapsed is too late: the transfer
				// has timed out. Abort rather than resurrect it — a caller that processes rx
				// before polling could otherwise let a late WAIT/CTS extend a dead transfer
				// past the deadline poll() would have aborted at.
				if l.n_bs_us != 0 && now >= l.fc_deadline {
					l.tx = .idle
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
				} else if fs == 1 { // WAIT: peer not ready — restart N_Bs, but bound the WAITs
					// check before incrementing so wft_count never exceeds wft_max (<=255) and
					// can't wrap back to 0 (which would let an endless-WAIT peer wedge the link).
					if l.wft_max != 0 && l.wft_count >= l.wft_max {
						l.tx = .idle // too many WAITs -> give up rather than wait forever
					} else {
						l.wft_count++
						l.fc_deadline = now + l.n_bs_us
					}
				} else if fs == 2 { // OVFLW / reserved -> abort
					l.tx = .idle
				}
			}
		}
		else {}
	}
}

// poll produces the next PDU to send, if any (FC has priority, then the tx FSM).
// tick advances the link's time-based state (the N_Bs flow-control timeout) independently
// of poll(). A caller that gates poll() on Tx-FIFO space (`for tx_ready() && poll(...)`) must
// call tick() every cycle so a full FIFO can't wedge the link in wait_fc forever — otherwise a
// dump on a down/quiet bus (FF sent, no FC, FIFO stays full) never reaches its abort deadline.
pub fn (mut l Link) tick(now u64) {
	if l.tx == .wait_fc && l.n_bs_us != 0 && now >= l.fc_deadline {
		l.tx = .idle // N_Bs elapsed with no flow control -> abort so the next tx is free
	}
}

pub fn (mut l Link) poll(now u64, mut out Pdu) bool {
	if l.fc_send {
		zero(mut out)
		out.data[0] = 0x30 // FC, CTS
		out.data[1] = l.bs
		out.data[2] = l.stmin
		l.fc_send = false
		return true
	}
	match l.tx {
		.send_sf {
			zero(mut out)
			out.data[0] = 0x00 | u8(l.tx_len)
			for i in 0 .. l.tx_len {
				out.data[1 + i] = l.tx_buf[i]
			}
			l.tx = .idle
			return true
		}
		.send_ff {
			zero(mut out)
			out.data[0] = 0x10 | u8((u32(l.tx_len) >> 8) & 0x0F)
			out.data[1] = u8(l.tx_len & 0xFF)
			for i in 0 .. 6 {
				out.data[2 + i] = l.tx_buf[i]
			}
			l.tx_pos = 6
			l.tx_sn = 1
			l.tx = .wait_fc
			l.fc_deadline = now + l.n_bs_us
			return true
		}
		.wait_fc {
			// N_Bs: a missed or never-sent FC (e.g. a dump issued before a receiver is
			// bound) must not leave the link busy forever — abort so the next dump is free.
			if l.n_bs_us != 0 && now >= l.fc_deadline {
				l.tx = .idle
			}
			return false
		}
		.send_cf {
			if now < l.next_us {
				return false
			}
			zero(mut out)
			out.data[0] = 0x20 | (l.tx_sn & 0x0F)
			mut n := l.tx_len - l.tx_pos
			if n > 7 {
				n = 7
			}
			for i in 0 .. n {
				out.data[1 + i] = l.tx_buf[l.tx_pos + i]
			}
			l.tx_pos += n
			l.tx_sn = (l.tx_sn + 1) & 0x0F
			l.next_us = now + l.peer_stmin
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

fn zero(mut p Pdu) {
	for i in 0 .. 8 {
		p.data[i] = 0
	}
}

// decode_stmin maps the FC STmin byte to microseconds: 0x00-0x7F ms, 0xF1-0xF9
// = 100-900 us; anything else -> 0.
fn decode_stmin(b u8) u64 {
	if b <= 0x7F {
		return u64(b) * 1000
	}
	if b >= 0xF1 && b <= 0xF9 {
		return u64(b - 0xF0) * 100
	}
	return 0
}
