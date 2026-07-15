module nm_can

import comm.com
import comm.nm
import driver.can

// NmModule — CAN network management as a ComModule (docs/com-modules.md): the bus owner's
// loop routes every frame in the cluster's NM id range to `on_peers` and drains `produce`
// for this node's own NM frame. The push-model sibling of Link (which PULLS from a Transport
// and is the host/superloop binding — a module must never drain the bus itself).
//
// The state machine (comm/nm) is transport-agnostic; this file only packs/unpacks the 8-byte
// PDU onto CAN frames. Application demand arrives via request()/release() — same-thread
// direct calls (e.g. the shell's `nm req`), cross-thread via the mode mailbox.
pub const endpoints = [
	com.Endpoint{
		name:  'peers'
		dir:   .rx
		dlc:   8
		range: true
		doc:   "the cluster's NM frames (an inclusive [lo, hi] id range)"
	},
	com.Endpoint{
		name: 'alive'
		dir:  .tx
		dlc:  8
		doc:  "this node's NM frame (conventionally base + node id)"
	},
]

pub struct NmModule {
pub mut:
	node_id  u8
	tx_id    u32
	pn_local u64
	sm       nm.Nm
}

// init prepares the module IN PLACE (the instance lives in a __global; see comm/shell for
// why module-sized structs never construct by value on a thread stack).
pub fn (mut m NmModule) init(node_id u8, tx_id u32, pn_local u64, t nm.Timings) {
	m.node_id = node_id
	m.tx_id = tx_id
	m.pn_local = pn_local
	m.sm = nm.Nm{
		cfg: t
	}
}

// on_peers serves the `peers` endpoint: an NM frame from the cluster. The router already
// gated the id range; here we only drop our own echo and short PDUs.
pub fn (mut m NmModule) on_peers(now u64, f can.Frame) {
	if f.id == m.tx_id || f.len < 8 {
		return
	}
	mut b := [8]u8{}
	for i in 0 .. 8 {
		b[i] = f.data[i]
	}
	m.sm.on_frame(now, nm.parse_frame(b))
}

// produce fills at most one tx frame per call: this node's NM message, when the state
// machine says one is due (the send itself counts as our bus presence).
pub fn (mut m NmModule) produce(now u64, mut f can.Frame) bool {
	if !m.sm.tick(now) {
		return false
	}
	bytes := m.sm.build_frame(m.node_id, m.pn_local).to_bytes()
	f.id = m.tx_id
	f.len = 8
	for i in 0 .. 8 {
		f.data[i] = bytes[i]
	}
	return true
}

// request/release/state delegate to the state machine for the application (and the shell).
pub fn (mut m NmModule) request(now u64) {
	m.sm.request(now)
}

pub fn (mut m NmModule) release() {
	m.sm.release()
}

// awake reports whether the network is up (anything but bus_sleep) — the
// producer gate for NM-gated COM tx (REQ-COM-007).
pub fn (m &NmModule) awake() bool {
	return m.sm.awake()
}

pub fn (m NmModule) state() nm.State {
	return m.sm.state
}

// state_str names the state for human output (the shell's `nm`).
pub fn (m NmModule) state_str() string {
	return match m.sm.state {
		.bus_sleep { 'bus_sleep' }
		.repeat_message { 'repeat_message' }
		.normal_operation { 'normal_operation' }
		.ready_sleep { 'ready_sleep' }
		.prepare_bus_sleep { 'prepare_bus_sleep' }
	}
}
