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
