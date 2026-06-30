module nm_can

// NM-over-CAN binding: drives the transport-agnostic NM state machine (comm/nm)
// onto a real CAN channel. Each service() drains the NM id range on rx (feeding
// frames into the state machine) and transmits this node's NM frame when one is
// due. This is the CAN transport for NM (CanNm); a future Ethernet binding
// (UDP-NM, different PDU) would be a sibling module over the same state machine.
//
// No-alloc: value types and fixed buffers only. The state machine and frame codec
// stay in comm/nm and know nothing of CAN — this is the only NM file that does.

import comm.nm
import driver.can

// Transport is the CAN frame sink/source the binding drives. driver.can.Channel
// satisfies it for a real bus; tests inject a fixed-size fake. This is the seam a
// non-CAN transport would plug a CAN-tunnelling channel into — NM itself stays
// above it.
pub interface Transport {
mut:
	recv(mut f can.Frame) bool
	send(f can.Frame) bool
}

pub struct Config {
pub:
	node_id  u8  // our source node id (NID byte)
	tx_id    u32 // CAN id we transmit our NM frame on
	rx_lo    u32 // NM id range (inclusive) we treat as NM traffic on rx
	rx_hi    u32
	pn_local u64 // partial networks this node requests (0 = none)
}

pub struct Link {
pub:
	cfg Config
pub mut:
	sm nm.Nm // the transport-agnostic state machine
}

// service polls rx (feeding every in-range NM frame into the state machine),
// advances the machine, and transmits this node's NM frame when one is due.
// Call once per tick with the current time (µs). Returns the network state.
pub fn (mut l Link) service(mut t Transport, now u64) nm.State {
	mut rx := can.Frame{}
	for t.recv(mut rx) {
		// only the NM id range, never our own echo, and a full 8-byte PDU
		if rx.id >= l.cfg.rx_lo && rx.id <= l.cfg.rx_hi && rx.id != l.cfg.tx_id && rx.len >= 8 {
			mut b := [8]u8{}
			for i in 0 .. 8 {
				b[i] = rx.data[i]
			}
			l.sm.on_frame(now, nm.parse_frame(b))
		}
	}
	if l.sm.tick(now) {
		bytes := l.sm.build_frame(l.cfg.node_id, l.cfg.pn_local).to_bytes()
		mut out := can.Frame{
			id:  l.cfg.tx_id
			len: 8
		}
		for i in 0 .. 8 {
			out.data[i] = bytes[i]
		}
		t.send(out)
	}
	return l.sm.state
}

// request/release/awake/state delegate to the state machine for the application.
pub fn (mut l Link) request(now u64) {
	l.sm.request(now)
}

pub fn (mut l Link) release() {
	l.sm.release()
}

pub fn (l Link) awake() bool {
	return l.sm.awake()
}

pub fn (l Link) state() nm.State {
	return l.sm.state
}
