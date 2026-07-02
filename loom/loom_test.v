module loom

// Per-core load accounting. account() is fed synthetic (busy, now) pairs so the
// load math is exercised deterministically, with no real clock.

// @verifies REQ-TELEM-001
// The load figure tracks the duty cycle. Feeding the scale bench's own shape —
// ~192 µs of handler work every 10 ms — must report ~1.9 % (~19 per-mille).
fn test_load_tracks_duty_cycle() {
	mut s := Scheduler{}
	mut now := u64(0)
	// 1.2 s of polling at 1 ms; a 192 µs handler burst every 10th poll (10 ms).
	for i in 0 .. 1200 {
		busy := if i % 10 == 0 { u64(192) } else { u64(0) }
		now += 1000
		s.account(busy, now)
	}
	lp := s.load_permille()
	assert lp >= 17 && lp <= 21, 'load ${lp} per-mille should be ~19 (1.9%), the scale bench duty cycle'
}

// An idle core (no handler work) reports zero.
fn test_idle_is_zero() {
	mut s := Scheduler{}
	mut now := u64(0)
	for _ in 0 .. 1200 {
		now += 1000
		s.account(0, now)
	}
	assert s.load_permille() == 0
}

// A core spending every poll entirely in handlers reports ~100 % (clamped at 1000).
fn test_saturated_is_full() {
	mut s := Scheduler{}
	mut now := u64(0)
	for _ in 0 .. 1200 {
		now += 1000
		s.account(1000, now) // the whole 1 ms poll spent in run()
	}
	lp := s.load_permille()
	assert lp >= 990 && lp <= 1000, 'saturated load ${lp} per-mille should be ~1000'
}

// Load is latched once per window, not per call: before the first full window
// elapses it stays at its initial 0.
fn test_no_update_before_window() {
	mut s := Scheduler{}
	mut now := u64(0)
	// only 0.5 s of polling -> window (1 s) hasn't closed yet
	for _ in 0 .. 500 {
		now += 1000
		s.account(192, now)
	}
	assert s.load_permille() == 0, 'load only latches after a full window'
}

// @verifies REQ-TELEM-001
// The fast (100 ms) window latches ten times sooner than the 1 s window. Feed a
// half-duty load for 100 ms: the 100 ms window reports ~50 % while the 1 s window
// (not yet closed) is still 0. All three windows track the same duty over their spans.
fn test_multi_window_latches_independently() {
	mut s := Scheduler{}
	mut now := u64(0)
	// ~110 ms of polling at 1 ms, half of each poll spent in handlers -> the 100 ms
	// window closes and latches; the 1 s / 10 s windows have not.
	for _ in 0 .. 110 {
		now += 1000
		s.account(500, now) // 500 µs busy of a 1 ms poll = 50 %
	}
	assert s.load_permille_100ms() >= 490 && s.load_permille_100ms() <= 510, '100 ms window ${s.load_permille_100ms()} should be ~500 per-mille'
	assert s.load_permille_1s() == 0, '1 s window has not closed yet'
	assert s.load_permille_10s() == 0, '10 s window has not closed yet'
	// carry on past 1 s: the 1 s window now latches to the same ~50 %.
	for _ in 0 .. 950 {
		now += 1000
		s.account(500, now)
	}
	assert s.load_permille_1s() >= 490 && s.load_permille_1s() <= 510, '1 s window ${s.load_permille_1s()} should be ~500 per-mille'
}

// Overruns are counted, not measured: the caller marks a pass that blew its tick, and
// the count accumulates (the reporter turns it into a per-period rate).
fn test_overrun_counter() {
	mut s := Scheduler{}
	assert s.overruns() == 0
	s.mark_overrun()
	s.mark_overrun()
	s.mark_overrun()
	assert s.overruns() == 3, 'overruns should accumulate'
}
