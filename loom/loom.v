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

// HandlerStat is one handler's per-invocation timing, updated by run_profiled. The
// duration is the handler's RESPONSE time (wall clock across the call); on a core with
// no interrupts/preemption that equals its CPU time. mean = total_us / count.
pub struct HandlerStat {
pub mut:
	last_us  u32 // duration of the most recent invocation
	max_us   u32 // longest invocation since the last reset
	count    u32 // invocations
	total_us u64 // cumulative time
}

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
	stats    [max_tasks]HandlerStat // per-handler timing (run_profiled)
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

// run_profiled is run() with per-handler timing: it dispatches every due handler,
// brackets each with `clock` (a monotonic µs source), records the duration into that
// handler's HandlerStat, and folds the summed handler time into the load windows — so it
// replaces run() + account() when per-handler stats are wanted. The clock is supplied so
// loom stays clock-free and unit-testable: pass osal.now_us on host, the DWT clock on
// target. Cost is two clock reads per dispatched handler.
pub fn (mut s Scheduler) run_profiled(clock fn () u64) {
	now := clock()
	mut busy := u64(0)
	for i in 0 .. s.count {
		if now >= s.due[i] {
			t0 := clock()
			s.handlers[i](s.ctx[i])
			dt := clock() - t0
			busy += dt
			mut st := &s.stats[i]
			st.last_us = u32(dt)
			if u32(dt) > st.max_us {
				st.max_us = u32(dt)
			}
			st.count++
			st.total_us += dt
			s.due[i] = now + s.period[i]
		}
	}
	s.account(busy, clock())
}

// handler_count is the number of registered handlers.
pub fn (s Scheduler) handler_count() int {
	return s.count
}

// handler_stat returns handler i's timing snapshot (zero for an out-of-range index).
pub fn (s Scheduler) handler_stat(i int) HandlerStat {
	if i < 0 || i >= s.count {
		return HandlerStat{}
	}
	return s.stats[i]
}

// reset_handler_max clears handler i's max (e.g. after reporting the peak-since-last).
pub fn (mut s Scheduler) reset_handler_max(i int) {
	if i >= 0 && i < s.count {
		s.stats[i].max_us = 0
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
