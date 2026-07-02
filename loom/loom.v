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

// Load is measured over three averaging windows at once: a fast 100 ms window that
// exposes bursts and overruns as they happen, a 1 s window for the steady figure, and
// a 10 s window for the slow trend. A single window hides an overrun spike by averaging
// it away; the fast one does not.
pub const load_windows = 3
const win_us = [u64(100_000), u64(1_000_000), u64(10_000_000)]!

pub struct Scheduler {
mut:
	handlers [max_tasks]Handler
	ctx      [max_tasks]voidptr
	period   [max_tasks]u64 // microseconds
	due      [max_tasks]u64 // next due time, microseconds
	count    int
	// Per-core load accounting, per window. The run loop feeds time spent in run() to
	// account(); once per window the busy/elapsed ratio latches into load_pm[win].
	busy_us  [load_windows]u64 // handler time accumulated this window
	win_base [load_windows]u64 // window start (monotonic µs); 0 = not started
	load_pm  [load_windows]u16 // last load, per-mille of wall clock (0..1000)
	overruns u32               // times a scheduling pass exceeded its tick budget
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
	for i in 0 .. load_windows {
		if s.win_base[i] == 0 {
			s.win_base[i] = now_us
		}
		s.busy_us[i] += busy_us
		elapsed := now_us - s.win_base[i]
		if elapsed >= win_us[i] {
			mut pm := s.busy_us[i] * 1000 / elapsed
			if pm > 1000 {
				pm = 1000 // clamp measurement noise (busy can't exceed wall time)
			}
			s.load_pm[i] = u16(pm)
			s.busy_us[i] = 0
			s.win_base[i] = now_us
		}
	}
}

// mark_overrun records that a scheduling pass ran longer than its tick budget — the
// core could not finish its due handlers within the period, so it is momentarily
// saturated. The caller (the super-loop) detects this: pass time > tick.
pub fn (mut s Scheduler) mark_overrun() {
	s.overruns++
}

// overruns is the running count of tick overruns since start (saturating handled by
// the reporter). A climbing count means the commanded work exceeds core capacity.
pub fn (s Scheduler) overruns() u32 {
	return s.overruns
}

// load_permille reports this core's most recent processor load over the 1 s window:
// the fraction of wall-clock time spent running handlers, 0..1000 (= 0..100.0%).
pub fn (s Scheduler) load_permille() u16 {
	return s.load_pm[1]
}

// load_permille_100ms / _1s / _10s report the same load over the fast / steady / trend
// windows. The 100 ms window surfaces bursts and overruns the 1 s window averages out.
pub fn (s Scheduler) load_permille_100ms() u16 {
	return s.load_pm[0]
}

pub fn (s Scheduler) load_permille_1s() u16 {
	return s.load_pm[1]
}

pub fn (s Scheduler) load_permille_10s() u16 {
	return s.load_pm[2]
}
