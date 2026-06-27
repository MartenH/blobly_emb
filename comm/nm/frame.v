module nm

// NM frame (PDU): 8 bytes — source node id, control bit vector, partial-network
// request mask. This is the on-wire encode/decode + the state-machine reactions
// to received control bits. Byte offsets here are the default layout; a partition
// can place NID/CBV elsewhere per config (see docs/nm.md). No-alloc: a value type.

// Control Bit Vector (byte 1) bits.
pub const cbv_repeat_msg_request = u8(0x01) // bit 0 — ask the cluster to re-announce
pub const cbv_ready_to_sleep     = u8(0x08) // bit 3 — sender has released the network
pub const cbv_active_wakeup      = u8(0x10) // bit 4 — sender actively woke the bus
pub const cbv_pn_info            = u8(0x40) // bit 6 — bytes 2..7 carry a PN mask

pub struct Frame {
pub:
	nid u8  // source node id
	cbv u8  // control bit vector
	pn  u64 // partial-network request mask (bytes 2..7, 48 bits)
}

// to_bytes packs the frame: NID @0, CBV @1, PN little-endian @2..7.
pub fn (f Frame) to_bytes() [8]u8 {
	mut b := [8]u8{}
	b[0] = f.nid
	b[1] = f.cbv
	for i in 0 .. 6 {
		b[2 + i] = u8((f.pn >> (8 * u64(i))) & 0xFF)
	}
	return b
}

// parse_frame decodes an 8-byte NM PDU.
pub fn parse_frame(b [8]u8) Frame {
	mut pn := u64(0)
	for i in 0 .. 6 {
		pn |= u64(b[2 + i]) << (8 * u64(i))
	}
	return Frame{
		nid: b[0]
		cbv: b[1]
		pn:  pn
	}
}

// build_frame builds this node's outgoing NM frame from the current state.
// `node_id` is our source id; `pn_local` is the partial networks we request.
pub fn (n Nm) build_frame(node_id u8, pn_local u64) Frame {
	mut cbv := u8(0)
	if n.active_woke {
		cbv |= cbv_active_wakeup
		if n.state == .repeat_message {
			cbv |= cbv_repeat_msg_request // active waker asks the cluster to re-sync
		}
	}
	if !n.requested {
		cbv |= cbv_ready_to_sleep
	}
	if pn_local != 0 {
		cbv |= cbv_pn_info
	}
	return Frame{
		nid: node_id
		cbv: cbv
		pn:  pn_local
	}
}

// on_frame feeds a received NM frame into the state machine: it keeps the network
// awake (on_rx), absorbs the remote PN demand, and re-syncs on a repeat-message
// request. The partition glue calls this on reception of an NM-range frame.
pub fn (mut n Nm) on_frame(now u64, f Frame) {
	n.on_rx(now)
	n.pn_remote |= f.pn
	if f.cbv & cbv_repeat_msg_request != 0 && n.state != .repeat_message {
		n.enter(.repeat_message, now)
	}
}

// pn_demanded reports whether partial network `idx` (0..47) is requested by any
// node — locally (`pn_local`) or by a node we have heard from.
pub fn (n Nm) pn_demanded(idx int, pn_local u64) bool {
	if idx < 0 || idx > 47 {
		return false
	}
	bit := u64(1) << u64(idx)
	return (pn_local | n.pn_remote) & bit != 0
}

// report returns the current network state for the ECU manager (Conductor).
pub fn (n Nm) report() State {
	return n.state
}
