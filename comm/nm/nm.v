module nm

// Network Management: coordinated bus sleep/wakeup (a lean CanNm).
//
// Every node periodically transmits an NM message while it needs the bus awake.
// Hearing ANY NM message keeps the network awake. When no node needs the bus and
// NM traffic stops, all nodes time out together and the bus sleeps. This module
// is the transport-agnostic state machine + timers (no-alloc); the partition glue
// turns `tick() == true` into an actual NM frame and feeds `on_rx` on reception.

pub enum State {
	bus_sleep         // dormant; request() or on_rx() wakes it
	repeat_message    // just awake: announce presence so all nodes synchronise
	normal_operation  // locally needed: transmit NM periodically
	ready_sleep       // not needed locally; stay awake only while others transmit
	prepare_bus_sleep // grace period with no traffic before sleeping
}

pub struct Timings {
pub:
	msg_cycle_us  u64 // period between our NM transmissions
	timeout_us    u64 // no NM heard for this long -> head toward sleep
	repeat_us     u64 // time spent in repeat_message after waking
	wait_sleep_us u64 // grace time in prepare_bus_sleep before bus_sleep
}

pub struct Nm {
pub:
	cfg Timings
pub mut:
	state          State = .bus_sleep
	requested      bool // local "I need the bus awake" flag
	tx_armed       bool // a transmission is due as soon as we tick
	last_tx_us     u64
	last_rx_us     u64
	state_since_us u64
}

// awake reports whether the network is up (anything but bus_sleep).
pub fn (n Nm) awake() bool {
	return n.state != .bus_sleep
}

fn (mut n Nm) enter(s State, now u64) {
	n.state = s
	n.state_since_us = now
	// transmitting states announce presence immediately on entry
	n.tx_armed = s == .repeat_message || s == .normal_operation
}

// request: the application needs the bus awake.
pub fn (mut n Nm) request(now u64) {
	n.requested = true
	match n.state {
		.bus_sleep, .prepare_bus_sleep { n.enter(.repeat_message, now) }
		.ready_sleep { n.enter(.normal_operation, now) }
		else {}
	}
}

// release: the application no longer needs the bus.
pub fn (mut n Nm) release() {
	n.requested = false
}

// on_rx: an NM message from another node was received. Keeps the network awake
// and wakes it from the sleep states (passive wakeup).
pub fn (mut n Nm) on_rx(now u64) {
	n.last_rx_us = now
	if n.state == .bus_sleep || n.state == .prepare_bus_sleep {
		n.enter(.repeat_message, now)
	}
}

// tick advances the state machine. Returns true if an NM message should be
// transmitted now (the caller sends it; that counts as our presence).
pub fn (mut n Nm) tick(now u64) bool {
	mut tx := false
	match n.state {
		.repeat_message {
			tx = n.tx_due(now)
			if now - n.state_since_us >= n.cfg.repeat_us {
				n.enter(if n.requested { State.normal_operation } else { State.ready_sleep },
					now)
			}
		}
		.normal_operation {
			tx = n.tx_due(now)
			if !n.requested {
				n.enter(.ready_sleep, now)
			}
		}
		.ready_sleep {
			// silent: kept awake only by others' NM traffic
			if n.requested {
				n.enter(.normal_operation, now)
			} else if now - n.last_rx_us >= n.cfg.timeout_us {
				n.enter(.prepare_bus_sleep, now)
			}
		}
		.prepare_bus_sleep {
			if n.requested {
				n.enter(.repeat_message, now)
			} else if now - n.state_since_us >= n.cfg.wait_sleep_us {
				n.enter(.bus_sleep, now)
			}
		}
		.bus_sleep {}
	}
	if tx {
		n.tx_armed = false
		n.last_tx_us = now
	}
	return tx
}

// tx_due: transmit on entry (armed) or once per msg_cycle thereafter.
fn (n Nm) tx_due(now u64) bool {
	return n.tx_armed || now - n.last_tx_us >= n.cfg.msg_cycle_us
}
