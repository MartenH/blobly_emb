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
