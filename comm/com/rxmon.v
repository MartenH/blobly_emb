module com

import comm.e2e

// Reception of one received frame (PDU) — the rule every owner of a COM bridge applies, the host
// bridge and the ThreadX comm thread alike (docs/diagnostics.md §3.2): which status a frame, a
// deadline or a commanded silence publishes to the frame's signals. The generated code checks the
// frame (SecOC verify, E2E check — the protections stay in their own modules) and hands the result
// here; it only maps the answer to a publish. No-alloc.

// RxPublish is what to publish to the frame's signals. The order is the generated RxStatus's
// (never_received ok timeout integrity), so a value maps onto it one to one.
pub enum RxPublish {
	none // nothing: a repeat, or reception is off
	ok // a good frame: its value, status ok
	timeout // silence, or a valid frame that came after the E2E timeout ran out unseen: value withheld
	integrity // the frame failed its protection check: value withheld
}

// RxMonitor is one received frame's state: its COM deadline (REQ-COM-005), its E2E receive state
// with E2E's own sender-loss timeout (REQ-E2E-002), and the lost frames a commanded silence hides.
pub struct RxMonitor {
pub mut:
	com RxState // the QM COM deadline: timeout_us 0 = none
	e2e e2e.RxState // check() a frame against it, then hand the Status to checked()
	// reception was found off since the last fresh frame: the gap the next one closes spans the
	// silence, and is not loss
	quiet  bool
	hidden u32 // lost frames counted while quiet (wrapping, like lost_frames)
	seen   u32 // e2e.lost_frames as of the last checked frame
}

// start arms both deadlines at the owner's start: a sender absent since then times out too.
pub fn (mut r RxMonitor) start(now u64) {
	r.com.arm(now)
	r.e2e.arm(now)
}

// silenced: a sampling of the reception gate found it off (UDS 0x28, or the network asleep).
pub fn (mut r RxMonitor) silenced() {
	r.quiet = true
}

// lost is the count of frames the E2E sequence showed missing, the commanded silences left out.
pub fn (r &RxMonitor) lost() u32 {
	return r.e2e.lost_frames - r.hidden
}

// checked: an authentic frame E2E judged `st`. `gate` = reception is on (publish); `suspended` = a
// silence is latched whose restart has not run, so the stale deadline judges nothing late. A
// usable frame refreshes the E2E timeout even with reception off — protection-level state, like the
// counter — and the COM deadline only when published; a corrupt one restarts the COM deadline (it
// runs from that frame) and the E2E timeout only once that has fired (e2e.RxState.receive_ex).
pub fn (mut r RxMonitor) checked(now u64, st e2e.Status, gate bool, suspended bool) RxPublish {
	gap := r.e2e.lost_frames - r.seen
	r.seen = r.e2e.lost_frames
	if r.quiet {
		r.hidden += gap
	}
	if gate && st.usable() {
		r.quiet = false
	}
	v := r.e2e.receive_ex(now, st, suspended)
	match v {
		.ok, .timeout {
			if !gate {
				return .none
			}
			r.com.on_receive(now)
			return if v == .timeout { RxPublish.timeout } else { RxPublish.ok }
		}
		.integrity {
			r.com.arm(now)
			return if gate { RxPublish.integrity } else { RxPublish.none }
		}
		.none {
			return .none
		}
	}
}

// received: an authentic frame with no E2E.
pub fn (mut r RxMonitor) received(now u64, gate bool) RxPublish {
	if !gate {
		return .none
	}
	r.com.on_receive(now)
	return .ok
}

// rejected: a frame SecOC refused. Both deadlines then run from it as from a corrupt frame — the
// same rule as an E2E CRC failure, whichever check caught it — and it never reaches E2E's sequence.
pub fn (mut r RxMonitor) rejected(now u64, gate bool) RxPublish {
	r.com.arm(now)
	_ = r.e2e.receive(now, .crc_error)
	return if gate { RxPublish.integrity } else { RxPublish.none }
}

// restart: reception is back after a silence — both deadlines run from now.
pub fn (mut r RxMonitor) restart(now u64) {
	r.com.on_receive(now)
	r.e2e.arm(now)
}

// expire polls both deadlines (each fires once, on its edge): true = publish `timeout`. One
// silence is one publication, whichever deadline saw it first or both at once.
pub fn (mut r RxMonitor) expire(now u64) bool {
	c := r.com.expired(now)
	e := r.e2e.expired(now)
	return c || e
}

// RxGate is a bus's reception gate, sampled by its owner wherever it can change: on = the
// application may receive (UDS 0x28 has reception on); silent = nothing is expected on the bus —
// reception off, or the network asleep. A silence is LATCHED until the owner settles it after its
// pass, so a switch off and on inside one pass is remembered like one spanning passes.
pub struct RxGate {
pub mut:
	on      bool
	silent  bool
	latched bool
}

// sample takes the gate's state now; true = silent (the owner marks its monitors silenced).
pub fn (mut g RxGate) sample(rx_on bool, awake bool) bool {
	g.on = rx_on
	g.silent = !rx_on || !awake
	if g.silent {
		g.latched = true
	}
	return g.silent
}

// suspended: a silence is latched whose restart has not run.
pub fn (g &RxGate) suspended() bool {
	return g.latched
}

// receiving: reception is on and the network awake — a publication now is a test result (asleep, a
// frame that arrives is published, but nothing is judged by it).
pub fn (g &RxGate) receiving() bool {
	return !g.silent
}

// live: the deadlines may fire and a signal's level may be judged — nothing is silent now or
// pending its restart.
pub fn (g &RxGate) live() bool {
	return !g.silent && !g.latched
}

// settle closes the pass, after its last sampling: true = the silence is over (restart every
// deadline on the bus).
pub fn (mut g RxGate) settle() bool {
	back := !g.silent && g.latched
	g.latched = g.silent
	return back
}
