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

// @verifies REQ-TELEM-003
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

// @verifies REQ-TELEM-004
// Covers ONLY the counter API (REQ-TELEM-004): a signalled overrun increments an
// observable, monotonic count. It deliberately does NOT test detection — that a pass
// actually exceeded its tick — which lives in the run loop / per-handler timing and is
// verified there, not here.
fn test_overrun_counter() {
	mut s := Scheduler{}
	assert s.overruns() == 0
	s.mark_overrun()
	s.mark_overrun()
	s.mark_overrun()
	assert s.overruns() == 3, 'overruns should accumulate'
}

// FakeClock is a deterministic µs source for run_profiled tests: a work_handler advances
// it by `step`, simulating a handler that runs for `step` µs, and the `clock` closure
// reads the same instance so bracket durations come out exact.
struct FakeClock {
mut:
	t    u64
	step u64
}

fn work_handler(ctx voidptr) {
	mut fc := unsafe { &FakeClock(ctx) }
	fc.t += fc.step
}

// @verifies REQ-TRACE-001
// run_profiled brackets each dispatched handler with the supplied clock and records its
// duration (last/max/count/total), and only fires a handler when its period has elapsed.
fn test_run_profiled_records_handler_time() {
	fc := &FakeClock{
		t:    0
		step: 50
	}
	clock := fn [fc] () u64 {
		return fc.t
	}
	mut s := Scheduler{}
	s.every(1000, work_handler, fc) // handler "runs" for 50 µs
	s.run_profiled(clock) // due at 0 -> fires; clock advances 0 -> 50
	st := s.handler_stat(0)
	assert st.count == 1, 'count=${st.count}'
	assert st.last_us == 50, 'last=${st.last_us}'
	assert st.max_us == 50, 'max=${st.max_us}'
	assert st.total_us == 50, 'total=${st.total_us}'
	// 50 µs elapsed < 1000 µs period -> not due, no second invocation
	s.run_profiled(clock)
	assert s.handler_stat(0).count == 1, 'must not re-fire before its period'
}

struct HookCapture {
mut:
	calls      int
	last_idx   int
	last_start u64
	last_dt    u64
}

fn capture_hook(ctx voidptr, idx int, start_us u64, dt_us u64) {
	mut c := unsafe { &HookCapture(ctx) }
	c.calls++
	c.last_idx = idx
	c.last_start = start_us
	c.last_dt = dt_us
}

// run_profiled calls the installed trace hook once per dispatched handler, with the
// handler's index, start time, and duration (the per-invocation record source).
fn test_run_profiled_trace_hook() {
	fc := &FakeClock{
		t:    0
		step: 50
	}
	clock := fn [fc] () u64 {
		return fc.t
	}
	mut cap := HookCapture{}
	mut s := Scheduler{}
	s.every(1000, work_handler, fc)
	s.set_trace_hook(capture_hook, &cap)
	s.run_profiled(clock)
	assert cap.calls == 1, 'hook calls=${cap.calls}'
	assert cap.last_idx == 0
	assert cap.last_start == 0, 'start=${cap.last_start}'
	assert cap.last_dt == 50, 'dt=${cap.last_dt}'
}

// A handler that "runs" for `step` µs while a higher-priority io thread also ran: the
// preemption clock advances inside the bracket and its delta must not be charged to the FB.
struct PreemptClock {
mut:
	t    u64 // wall µs
	io   u64 // io exec µs (monotonic)
	step u64
	iodt u64
}

fn preempted_handler(ctx voidptr) {
	mut pc := unsafe { &PreemptClock(ctx) }
	pc.t += pc.step + pc.iodt // wall time includes the io thread's run
	pc.io += pc.iodt
}

// @verifies REQ-TRACE-001
fn test_run_profiled_excl_subtracts_preemption() {
	pc := &PreemptClock{
		step: 50
		iodt: 30
	}
	clock := fn [pc] () u64 {
		return pc.t
	}
	preempt := fn [pc] () u64 {
		return pc.io
	}
	mut cap := HookCapture{}
	mut s := Scheduler{}
	s.every(1000, preempted_handler, pc)
	s.set_trace_hook(capture_hook, &cap)
	s.run_profiled_excl(clock, preempt)
	st := s.handler_stat(0)
	assert st.last_us == 50, 'last=${st.last_us} (wall 80 minus 30 io)'
	assert st.total_us == 50, 'total=${st.total_us}'
	// the trace record carries the same io-excluded duration
	assert cap.calls == 1
	assert cap.last_dt == 50, 'trace dur=${cap.last_dt}'
	// and run_profiled (no preemption clock) still reports the plain wall bracket
	mut p := unsafe { &PreemptClock(pc) }
	p.t = 1000
	p.io = 0
	s.run_profiled(clock)
	assert s.handler_stat(0).last_us == 80, 'wall=${s.handler_stat(0).last_us}'
}
