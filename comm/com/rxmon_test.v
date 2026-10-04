module com

import comm.e2e

// @verifies REQ-COM-005 REQ-COM-008 REQ-COM-009 REQ-E2E-002
// RxMonitor + RxGate against a reference model of the bridge pass they replace: the host bridge's
// generated receive rules as they stood before the monitor existed (one state variable per rule,
// written out in pass order), extended by one statement — the network asleep is a silence like
// reception switched off, except that it hides no value. Random passes interleave good frames,
// counter gaps, repeats, corrupt frames, SecOC refusals, a 0x28 switch inside the drain and NM
// sleep with the deadlines, and both sides must publish the same statuses with the same lost count.
const data_id = u16(0x44)
const crc_pos = 4
const ctr_pos = 5
const dlc = 8

// Cfg is one received frame's configuration.
struct Cfg {
	com_us u64 // COM deadline, 0 = none
	e2e_us u64 // E2E timeout, 0 = none (no E2E when !e2e)
	e2e    bool
	secoc  bool
	diag   bool // a diagnostic server can switch reception off (0x28)
	nm     bool // the bus sleeps
}

// Ev is one thing inside a pass's drain.
enum Ev {
	good // the next frame in sequence
	gap // two frames skipped, then one
	repeat // the last frame again
	corrupt // a CRC failure
	forged // a frame SecOC refuses
	rx_off // a functional 0x28 switching reception off
	rx_on // and on again
}

// Pub is one publication: the status and the lost count it carries.
struct Pub {
	st   RxPublish
	lost u32
}

// --- the reference: the pre-monitor bridge pass, one variable per rule ---------------------------
struct Ref {
	cfg Cfg
mut:
	com     RxState
	e2e     e2e.RxState
	was_off bool // the 0x28 silence latch (diag_rx_was_off)
	quiet   bool // e2e_quiet
	hidden  u32 // e2e_hidden
	pubs    []Pub
}

fn (mut r Ref) publish(st RxPublish) {
	r.pubs << Pub{st, r.e2e.lost_frames - r.hidden}
}

fn (mut r Ref) sample(rx_on bool, awake bool) bool {
	if !rx_on || !awake {
		r.was_off = true
		r.quiet = true
	}
	return rx_on
}

fn (mut r Ref) frame(now u64, f [64]u8, forged bool, rx_ok bool) {
	if r.cfg.secoc && forged {
		// rx_integrity(rearm_e2e = true)
		if r.cfg.com_us > 0 {
			r.com.arm(now)
		}
		if r.cfg.e2e && r.cfg.e2e_us > 0 {
			_ = r.e2e.receive(now, .crc_error)
		}
		if rx_ok {
			r.publish(.integrity)
		}
		return
	}
	if r.cfg.e2e {
		lf := r.e2e.lost_frames
		chk := r.e2e.check(&f[0], dlc, data_id, crc_pos, ctr_pos)
		if r.quiet {
			r.hidden += r.e2e.lost_frames - lf
		}
		if rx_ok && chk.usable() {
			r.quiet = false
		}
		v := r.e2e.receive_ex(now, chk, r.was_off)
		if v == .ok || v == .timeout {
			if rx_ok {
				r.publish(if v == .timeout { RxPublish.timeout } else { RxPublish.ok })
				if r.cfg.com_us > 0 {
					r.com.on_receive(now)
				}
			}
		} else if v == .integrity {
			if r.cfg.com_us > 0 {
				r.com.arm(now)
			}
			if rx_ok {
				r.publish(.integrity)
			}
		}
		return
	}
	if rx_ok {
		r.publish(.ok)
		if r.cfg.com_us > 0 {
			r.com.on_receive(now)
		}
	}
}

fn (mut r Ref) after(now u64, rx_on bool, awake bool) {
	r.sample(rx_on, awake)
	silent := !rx_on || !awake
	if !silent && r.was_off {
		if r.cfg.com_us > 0 {
			r.com.on_receive(now)
		}
		if r.cfg.e2e_us > 0 {
			r.e2e.arm(now)
		}
	}
	r.was_off = silent
	// the two deadlines, polled in turn; one silence is one publication
	c := !silent && r.com.expired(now)
	e := !silent && r.e2e.expired(now)
	if c || e {
		r.publish(.timeout)
	}
}

// --- the implementation, driven the way the generator drives it ---------------------------------
struct Impl {
	cfg Cfg
mut:
	mon  RxMonitor
	gate RxGate
	pubs []Pub
}

fn (mut s Impl) note(p RxPublish) {
	if p != .none {
		s.pubs << Pub{p, s.mon.lost()}
	}
}

fn (mut s Impl) sample(rx_on bool, awake bool) {
	if s.gate.sample(rx_on, awake) {
		s.mon.silenced()
	}
}

fn (mut s Impl) frame(now u64, f [64]u8, forged bool) {
	if s.cfg.secoc && forged {
		s.note(s.mon.rejected(now, s.gate.on))
		return
	}
	if s.cfg.e2e {
		chk := s.mon.e2e.check(&f[0], dlc, data_id, crc_pos, ctr_pos)
		s.note(s.mon.checked(now, chk, s.gate.on, s.gate.suspended()))
		return
	}
	s.note(s.mon.received(now, s.gate.on))
}

fn (mut s Impl) after(now u64, rx_on bool, awake bool) {
	s.sample(rx_on, awake)
	if s.gate.settle() {
		s.mon.restart(now)
	}
	if s.gate.live() && s.mon.expire(now) {
		s.note(.timeout)
	}
}

// --- the random passes --------------------------------------------------------------------------
struct Rng {
mut:
	x u64
}

fn (mut r Rng) next(n int) int {
	r.x = r.x * 6364136223846793005 + 1442695040888963407
	return int((r.x >> 33) % u64(n))
}

struct Sender {
mut:
	tx   e2e.TxState
	last [64]u8
}

fn (mut s Sender) next(skip int) [64]u8 {
	mut f := [64]u8{}
	for _ in 0 .. skip {
		s.tx.protect(&f[0], dlc, data_id, crc_pos, ctr_pos)
	}
	f[0] = u8(s.tx.counter * 7)
	s.tx.protect(&f[0], dlc, data_id, crc_pos, ctr_pos)
	s.last = f
	return f
}

fn run(cfg Cfg, seed u64, passes int) []Pub {
	mut rng := Rng{seed}
	mut ref := Ref{
		cfg: cfg
	}
	ref.com.timeout_us = cfg.com_us
	ref.e2e.timeout_us = cfg.e2e_us
	ref.com.arm(0)
	ref.e2e.arm(0)
	mut im := Impl{
		cfg: cfg
	}
	im.mon.com.timeout_us = cfg.com_us
	im.mon.e2e.timeout_us = cfg.e2e_us
	im.mon.start(0)
	// the gate's state before the first pass: reception on, network awake
	im.gate.sample(true, true)
	mut snd := Sender{}
	mut now := u64(0)
	mut rx_on := true
	mut awake := true
	for p in 0 .. passes {
		now += u64(1 + rng.next(40)) * 1000 // 1..40 ms between passes, against 50..300 ms deadlines
		// the gate's slow changes, made between passes: a 0x28 answered last pass, the network
		// falling asleep or waking
		if cfg.diag && rng.next(12) == 0 {
			rx_on = !rx_on
		}
		if cfg.nm && rng.next(15) == 0 {
			awake = !awake
		}
		ok := ref.sample(rx_on, awake)
		im.sample(rx_on, awake)
		mut drain_rx := ok
		// a quiet sender, mostly: frames in about a third of the passes
		n := if rng.next(3) == 0 { 1 + rng.next(3) } else { 0 }
		for _ in 0 .. n {
			ev := unsafe { Ev(rng.next(7)) }
			match ev {
				.rx_off, .rx_on {
					if !cfg.diag {
						continue
					}
					rx_on = ev == .rx_on
					drain_rx = ref.sample(rx_on, awake)
					im.sample(rx_on, awake)
					continue
				}
				else {}
			}
			mut f := [64]u8{}
			mut forged := false
			match ev {
				.good {
					f = snd.next(0)
				}
				.gap {
					f = snd.next(2)
				}
				.repeat {
					f = snd.last
				}
				.corrupt {
					f = snd.next(0)
					f[0] ^= 0x5A
				}
				else {
					f = snd.next(0)
					forged = true
				}
			}
			ref.frame(now, f, forged, drain_rx)
			im.frame(now, f, forged)
		}
		ref.after(now, rx_on, awake)
		im.after(now, rx_on, awake)
		assert im.pubs == ref.pubs, 'cfg ${cfg} seed ${seed}: pass ${p} differs\nref  ${ref.pubs}\nimpl ${im.pubs}'
	}
	assert im.mon.hidden <= im.mon.e2e.lost_frames
	return im.pubs
}

const cfgs = [
	Cfg{
		com_us: 120_000
	},
	Cfg{
		com_us: 120_000
		diag: true
	},
	Cfg{
		e2e: true
		e2e_us: 150_000
		diag: true
	},
	Cfg{
		com_us: 100_000
		e2e: true
		e2e_us: 150_000
		diag: true
		nm: true
	},
	Cfg{
		com_us: 200_000
		e2e: true
		e2e_us: 80_000
		secoc: true
		diag: true
	},
	Cfg{
		e2e: true
		e2e_us: 60_000
		nm: true
	},
	Cfg{
		com_us: 90_000
		secoc: true
		diag: true
		nm: true
	},
]

fn test_the_monitor_matches_the_reference_pass() {
	// what the passes exercised: every status published, and lost counted with and without a
	// silence hiding some of it — a model that never reaches a case proves nothing about it
	mut seen := map[RxPublish]int{}
	mut lost_shown := 0
	for cfg in cfgs {
		for seed in 1 .. 41 {
			for p in run(cfg, u64(seed), 400) {
				seen[p.st]++
				if p.lost > 0 {
					lost_shown++
				}
			}
		}
	}
	for st in [RxPublish.ok, .timeout, .integrity] {
		assert seen[st] > 50, '${st} published only ${seen[st]} times'
	}
	assert lost_shown > 50
}

// --- the rules one at a time, each with its own reason to exist --------------------------------
fn protected(mut s Sender, skip int) [64]u8 {
	return s.next(skip)
}

fn mon(com_us u64, e2e_us u64) RxMonitor {
	mut m := RxMonitor{}
	m.com.timeout_us = com_us
	m.e2e.timeout_us = e2e_us
	m.start(0)
	return m
}

fn test_a_sender_absent_since_start_times_out_once() {
	mut m := mon(100_000, 0)
	assert !m.expire(100_000)
	assert m.expire(100_001)
	assert !m.expire(500_000), 'one silence is one publication'
}

fn test_both_deadlines_running_out_together_publish_once() {
	mut m := mon(100_000, 100_000)
	assert m.expire(200_000)
	assert !m.expire(300_000)
}

fn test_a_valid_frame_after_an_unseen_e2e_timeout_is_late() {
	mut s := Sender{}
	mut m := mon(0, 100_000)
	f := protected(mut s, 0)
	st := m.e2e.check(&f[0], dlc, data_id, crc_pos, ctr_pos)
	assert m.checked(150_000, st, true, false) == .timeout
	// ...unless a silence is latched: then the deadline it would be judged by is stale
	mut m2 := mon(0, 100_000)
	st2 := m2.e2e.check(&f[0], dlc, data_id, crc_pos, ctr_pos)
	assert m2.checked(150_000, st2, true, true) == .ok
}

fn test_a_corrupt_frame_restarts_the_com_deadline_but_not_a_running_e2e_one() {
	mut s := Sender{}
	mut m := mon(100_000, 100_000)
	mut f := protected(mut s, 0)
	f[0] ^= 1
	st := m.e2e.check(&f[0], dlc, data_id, crc_pos, ctr_pos)
	assert m.checked(90_000, st, true, false) == .integrity
	// the COM deadline now runs from the corrupt frame; the E2E one still from start
	assert !m.com.expired(150_000)
	assert m.e2e.expired(150_000), 'a corrupt-only sender kept E2E alive'
}

fn test_frames_missed_while_reception_is_off_are_not_lost() {
	mut s := Sender{}
	mut m := mon(0, 1_000_000)
	mut g := RxGate{}
	g.sample(true, true)
	f1 := protected(mut s, 0)
	m.checked(1000, m.e2e.check(&f1[0], dlc, data_id, crc_pos, ctr_pos), g.on, g.suspended())
	if g.sample(false, true) {
		m.silenced()
	}
	// the sender goes on while reception is off: these frames are commanded silence
	for _ in 0 .. 3 {
		protected(mut s, 0)
	}
	g.settle()
	g.sample(true, true)
	if g.settle() {
		m.restart(2000)
	}
	f2 := protected(mut s, 0)
	assert m.checked(3000, m.e2e.check(&f2[0], dlc, data_id, crc_pos, ctr_pos), g.on, g.suspended()) == .ok
	assert m.e2e.lost_frames == 3
	assert m.lost() == 0
	// a real gap after it is counted
	f3 := protected(mut s, 1)
	m.checked(4000, m.e2e.check(&f3[0], dlc, data_id, crc_pos, ctr_pos), g.on, g.suspended())
	assert m.lost() == 1
}

fn test_the_network_asleep_suspends_the_deadlines_but_hides_no_value() {
	mut m := mon(100_000, 0)
	mut g := RxGate{}
	g.sample(true, true)
	g.settle()
	assert g.sample(true, false), 'asleep is silent'
	assert g.on, 'asleep, reception is still on: a frame that arrives is published'
	assert m.received(10_000, g.on) == .ok
	g.settle()
	assert !g.live()
	assert !(g.live() && m.expire(500_000)), 'a deadline fired while the network slept'
	// on wake the deadline restarts from the wake, not from the last frame
	g.sample(true, true)
	assert g.settle()
	m.restart(600_000)
	assert g.live()
	assert !m.expire(650_000)
	assert m.expire(700_001)
}

fn test_a_switch_off_and_on_inside_one_pass_is_a_silence() {
	mut g := RxGate{}
	g.sample(true, true)
	g.settle()
	assert g.sample(false, true)
	assert !g.sample(true, true)
	assert g.suspended(), 'the off was forgotten by the on that followed it'
	assert g.settle(), 'reception came back: the deadlines restart'
	assert !g.suspended()
}

fn test_reception_back_is_not_live_until_its_restart_has_run() {
	mut g := RxGate{}
	g.sample(false, true)
	assert !g.settle(), 'reception is still off: nothing to restart'
	assert !g.settle()
	// the next pass top: reception is back, its restart runs after the drain — until then a
	// signal's level is not judged (the deadline behind it is the stale pre-silence one)
	g.sample(true, true)
	assert !g.live()
	assert g.settle()
	assert g.live()
}
