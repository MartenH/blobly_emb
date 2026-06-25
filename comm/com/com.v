module com

// COM per-PDU transmission/reception behaviour, no-alloc. The generated bus
// bridge holds one TxState per tx PDU and one RxState per rx PDU and steps them
// each tick. The timing + change-detection live here so they are shared across
// every example and unit-tested independently of any DBC.

// max_pdu bounds a PDU payload (one CAN-FD frame). TX change-detection compares
// up to this many bytes.
pub const max_pdu = 64

// TxMode is how a tx PDU is scheduled onto the bus.
pub enum TxMode {
	cyclic    // every cycle_us
	event     // on change, debounced by min_delay_us
	mixed     // cyclic heartbeat + immediate on change
	triggered // only when trigger() was called
}

pub struct TxState {
pub mut:
	mode         TxMode
	cycle_us     u64
	min_delay_us u64
	last_us      u64
	sent         bool
	pending      bool        // explicit trigger requested
	last         [max_pdu]u8 // last payload sent (change detection)
}

// should_send decides whether the freshly packed payload `data` (len bytes) goes
// out now, and records it if so. Called once per bridge tick per tx PDU.
pub fn (mut t TxState) should_send(now u64, data [max_pdu]u8, len u8) bool {
	changed := !t.sent || !same(t.last, data, len)
	cyclic_due := (t.mode == .cyclic || t.mode == .mixed) && (!t.sent || now - t.last_us >= t.cycle_us)
	event_due := (t.mode == .event || t.mode == .mixed) && changed && (!t.sent || now - t.last_us >= t.min_delay_us)
	trig_due := t.mode == .triggered && t.pending
	send := cyclic_due || event_due || trig_due
	if send {
		for i in 0 .. int(len) {
			t.last[i] = data[i]
		}
		t.last_us = now
		t.sent = true
		t.pending = false
	}
	return send
}

// trigger requests one transmission (TxMode.triggered).
pub fn (mut t TxState) trigger() {
	t.pending = true
}

fn same(a [max_pdu]u8, b [max_pdu]u8, len u8) bool {
	for i in 0 .. int(len) {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// RxState monitors a reception deadline for a periodic rx PDU.
pub struct RxState {
pub mut:
	timeout_us u64
	last_us    u64
	received   bool
	timedout   bool
}

// on_receive records a fresh reception of the PDU.
pub fn (mut r RxState) on_receive(now u64) {
	r.last_us = now
	r.received = true
	r.timedout = false
}

// expired returns true exactly once, on the edge where the deadline passes — the
// bridge then invalidates the PDU's signals. timeout_us == 0 disables monitoring.
pub fn (mut r RxState) expired(now u64) bool {
	if r.timeout_us == 0 || !r.received || r.timedout {
		return false
	}
	if now - r.last_us > r.timeout_us {
		r.timedout = true
		return true
	}
	return false
}
