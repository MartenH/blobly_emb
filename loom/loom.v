module loom

// The Loom: the wiring + dispatch layer (the de-AUTOSAR'd "RTE").
// One Scheduler instance per partition/core. Fully static: a fixed table of
// (handler, context, period), zero allocation. Each handler gets a context
// pointer to its partition state — no closures, no globals.
//
// Host/sim: this cyclic scheduler runs in the partition's thread. Target: each
// task maps onto an OSAL/ThreadX task pinned to the partition's core.

pub type Handler = fn (ctx voidptr)

const max_tasks = 32

pub struct Scheduler {
mut:
	handlers [max_tasks]Handler
	ctx      [max_tasks]voidptr
	period   [max_tasks]u64 // microseconds
	due      [max_tasks]u64 // next due time, microseconds
	count    int
	// Per-core load accounting. The run loop feeds time spent in run() to
	// account(); once per window the busy/elapsed ratio latches into load_pm.
	win_us   u64 = 1_000_000 // load-averaging window (default 1 s)
	busy_us  u64             // handler time accumulated this window
	win_base u64             // window start (monotonic µs); 0 = not started
	load_pm  u16             // last load, per-mille of wall clock (0..1000)
}

// every registers a handler + its partition-state context to run on a fixed
// period. No-op if the static table is full.
pub fn (mut s Scheduler) every(period_us u64, h Handler, ctx voidptr) {
	if s.count >= max_tasks {
		return
	}
	s.handlers[s.count] = h
	s.ctx[s.count] = ctx
	s.period[s.count] = period_us
	s.due[s.count] = 0
	s.count++
}

// run dispatches every handler whose period has elapsed. Call frequently with
// the current monotonic time.
pub fn (mut s Scheduler) run(now_us u64) {
	for i in 0 .. s.count {
		if now_us >= s.due[i] {
			s.handlers[i](s.ctx[i])
			s.due[i] = now_us + s.period[i]
		}
	}
}

// account folds one scheduling pass into this core's load figure. The run loop
// measures the wall-clock time spent in run() (the handler work) and passes it
// here with the current time; once per window the busy/elapsed ratio is latched
// into load_pm. Kept clock-free (the caller supplies the time) so it stays
// deterministic and unit-testable.
pub fn (mut s Scheduler) account(busy_us u64, now_us u64) {
	if s.win_base == 0 {
		s.win_base = now_us
	}
	s.busy_us += busy_us
	elapsed := now_us - s.win_base
	if elapsed >= s.win_us {
		mut pm := s.busy_us * 1000 / elapsed
		if pm > 1000 {
			pm = 1000 // clamp measurement noise (busy can't exceed wall time)
		}
		s.load_pm = u16(pm)
		s.busy_us = 0
		s.win_base = now_us
	}
}

// load_permille reports this core's most recent processor load: the fraction of
// wall-clock time spent running handlers over the last window, 0..1000 (= 0..100.0%).
pub fn (s Scheduler) load_permille() u16 {
	return s.load_pm
}
