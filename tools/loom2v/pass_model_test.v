module main

// @verifies REQ-COM-009 REQ-DIAG-011
import comm.com
import comm.e2e
import comm.fault
import comm.nm
import comm.uds

// A model of the ThreadX comm thread's pass: the real receive rule (com.RxMonitor / RxGate), NM
// (comm/nm), debounce and fault memory (comm/fault), run step by step in comm_pass_order — the order
// the generator emits (rx_target_test.v pins the emitted order to the same constant). Each step does
// what the generator emits for it. Mid-pass state changes are driven — a 0x28 on CAN inside the
// drain, a 0x28 over DoIP, an NM frame waking the network inside the drain, a deadline running out —
// and the outcomes asserted: no frame passes a closed gate, an occurrence after a wake is recorded
// in the operation cycle, a DTC is never persisted with its snapshot still due.
enum Ev {
	good
	corrupt
	rx_off // a 0x28 on CAN disabling reception, served inside the drain
	rx_on
	nm_wake // a peer's NM frame
}

struct PassModel {
mut:
	gate   com.RxGate
	mon    com.RxMonitor
	nmm    nm.Nm
	mem    fault.Memory
	srv    uds.Server
	integ  fault.Debounce // slot 0: SafetyCmd integrity
	tmo    fault.Debounce // slot 1: SafetyCmd timeout, with a snapshot
	tx     e2e.TxState
	rx_on  bool = true
	seen   bool // NM as the drain last acted on it
	fcycle bool // the operation cycle follows NM
	now    u64
	// what the steps observed
	closed_publications int // a value published while 0x28 had reception off
	publications        int
	consumed_late       bool // a consume after this pass's persist step: its snapshot waits a pass
	persisted_due       bool // a persist found a snapshot still due
}

fn new_model() PassModel {
	mut p := PassModel{
		nmm: nm.Nm{
			cfg: nm.Timings{
				msg_cycle_us: 100_000
				timeout_us: 300_000
				repeat_us: 200_000
				wait_sleep_us: 150_000
			}
		}
	}
	p.mon.e2e.timeout_us = 300_000
	p.mon.start(0)
	p.mem.slots[0].dtc = 0xC46400
	p.mem.slots[1].dtc = 0xC16400
	p.mem.slots[1].freeze[0] = 0xF190
	p.mem.slots[1].freeze_len[0] = 2
	p.mem.slots[1].nfreeze = 1
	p.mem.n = 2
	p.mem.cap = 1
	p.mem.init()
	p.srv.dids[0] = uds.Did{
		id: 0xF190
		len: 2
	}
	p.srv.ndid = 1
	p.integ = fault.Debounce{
		fail_thr: 1
		pass_thr: 1
		jump: true
	}
	p.tmo = p.integ
	return p
}

// hooks: the signal-status faults' share of one publication (rx_publish_hooks)
fn (mut p PassModel) publish(r com.RxPublish, persisted bool) {
	p.publications++
	if !p.rx_on {
		p.closed_publications++
	}
	if persisted {
		p.consumed_late = true
	}
	ri := if r == .integrity {
		fault.TestResult.failed
	} else if r == .ok { fault.TestResult.passed } else { fault.TestResult.not_tested }
	rt := if r == .timeout {
		fault.TestResult.failed
	} else if r == .ok { fault.TestResult.passed } else { fault.TestResult.not_tested }
	p.integ.apply(p.mem.control_gen(0), p.mem.control_held(0))
	p.integ.step(ri, p.now, p.gate.receiving())
	p.mem.consume(0, p.integ.rep)
	p.tmo.apply(p.mem.control_gen(1), p.mem.control_held(1))
	p.tmo.step(rt, p.now, p.gate.receiving())
	p.mem.consume(1, p.tmo.rep)
}

fn (mut p PassModel) sample() {
	if p.gate.sample(p.rx_on, p.nmm.awake()) {
		p.mon.silenced()
	}
}

// cycle: the operation cycle follows NM (fault_target_cycle)
fn (mut p PassModel) cycle() {
	if p.nmm.awake() != p.fcycle {
		p.fcycle = p.nmm.awake()
		if p.fcycle {
			p.mem.cycle_start()
		} else {
			p.mem.end_cycle_after(p.now, 100_000)
		}
	}
	if p.mem.cycle_end_due(p.now) {
		p.mem.cycle_end()
	}
}

// pass runs one comm pass, in comm_pass_order, with `remote` a DoIP 0x28 waiting (0 none, 1 off,
// 2 on) and `drain` the FIFO's contents
fn (mut p PassModel) pass(dt u64, remote int, drain []Ev) {
	p.now += dt
	mut persisted := false
	for step in comm_pass_order {
		match step {
			.housekeep, .reports {}
			.open {
				p.sample()
			}
			.remote {
				if remote != 0 {
					p.rx_on = remote == 2
					p.sample()
				}
			}
			.drain {
				p.seen = p.nmm.awake()
				for ev in drain {
					match ev {
						.good, .corrupt {
							mut f := [64]u8{}
							p.tx.protect(&f[0], 8, 0x55, 2, 3)
							if ev == .corrupt {
								f[2] ^= 0xFF
							}
							chk := p.mon.e2e.check(&f[0], 8, 0x55, 2, 3)
							r := p.mon.checked(p.now, chk, p.gate.on, p.gate.receiving(), p.gate.suspended())
							if r != .none {
								p.publish(r, persisted)
							}
						}
						.rx_off, .rx_on {
							p.rx_on = ev == .rx_on
							p.sample()
						}
						.nm_wake {
							p.nmm.on_rx(p.now)
							if p.nmm.awake() != p.seen {
								p.seen = p.nmm.awake()
								p.sample()
								p.cycle()
							}
						}
					}
				}
			}
			.tick {
				_ = p.nmm.tick(p.now)
			}
			.cycle {
				p.cycle()
			}
			.settle {
				p.sample()
				if p.gate.settle() {
					p.mon.restart(p.now)
				}
				if p.gate.live() && p.mon.expire(p.now) {
					p.publish(.timeout, persisted)
				}
			}
			.persist {
				if p.mem.capture_due() {
					p.mem.capture(&p.srv)
				}
				if p.mem.capture_due() {
					p.persisted_due = true
				}
				persisted = true
			}
		}
	}
}

// 0x28 switching reception off inside the drain, on CAN or over DoIP: no frame drained after it in
// that pass reaches the FB, and none while it stays off.
fn test_no_frame_passes_a_closed_gate() {
	mut p := new_model()
	p.nmm.request(0)
	p.pass(10_000, 0, [])
	p.pass(10_000, 0, [Ev.good, .rx_off, .good, .good])
	p.pass(10_000, 0, [Ev.good])
	p.pass(10_000, 0, [Ev.rx_on, .good])
	// a DoIP 0x28 waiting when the pass begins is served before the FIFO is drained: none of
	// the frames queued behind it reaches the FB
	before := p.publications
	p.pass(10_000, 1, [Ev.good, .good])
	assert p.publications == before, 'frames drained after a waiting DoIP 0x28 reached the FB'
	assert p.closed_publications == 0
}

// An NM frame waking the network inside the drain: the corrupt frame after it is an occurrence in
// the operation cycle the wake began — recorded, not dropped as outside a cycle or not tested.
fn test_an_occurrence_after_a_wake_in_the_drain_is_recorded() {
	mut p := new_model()
	p.pass(10_000, 0, []) // asleep: no cycle
	assert !p.mem.cycle_active
	p.pass(10_000, 0, [Ev.nm_wake, .corrupt, .good])
	s := p.mem.slots[0].status
	assert s & fault.test_failed_this_cycle != 0, 'the integrity failure after the wake was lost (status 0x${s.hex()})'
	assert s & fault.confirmed != 0
}

// A deadline running out is consumed at settle: its snapshot is captured before the pass's journal
// write, never a pass later.
fn test_a_persisted_dtc_never_has_its_snapshot_still_due() {
	mut p := new_model()
	p.nmm.request(0)
	for _ in 0 .. 60 {
		p.pass(10_000, 0, [])
	}
	assert p.mem.slots[1].status & fault.confirmed != 0, 'the deadline never ran out'
	assert p.mem.slots[1].entry != 0, 'no snapshot was taken'
	assert !p.consumed_late, 'an occurrence was consumed after the journal write'
	assert !p.persisted_due
}

// The NM sleep is one silence for the lost count: frames arriving in it hide their gaps.
fn test_frames_in_an_nm_sleep_count_no_loss() {
	mut p := new_model()
	p.pass(10_000, 0, [])
	// the sender skips while the network sleeps; its frames still arrive
	p.tx.counter = (p.tx.counter + 3) % 15
	p.pass(10_000, 0, [Ev.good])
	p.tx.counter = (p.tx.counter + 2) % 15
	p.pass(10_000, 0, [Ev.good, .good])
	assert p.mon.lost() == 0
}
