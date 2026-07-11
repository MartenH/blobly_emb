module trace

// The FB enter/exit hook — the platform side of "hooks record, the module serves the bus"
// (docs/com-modules.md). The Loom's run_profiled calls fb_hook once per dispatched handler
// (it matches loom.RunHook: fn (voidptr, int, u64, u64)); the hook timestamps and pushes a
// Record into the ring it was wired to. This used to be ~30 lines of generated code per
// config — it is pure platform logic, written once.
//
// The ISR and thread hook families live where those events are owned (the Cortex-M port's
// exec-change hooks, the RTOS); this file is the FB family.
pub struct Capture {
pub mut:
	buf       &TraceBuffer = unsafe { nil } // the ring records land in
	start     u64 // wall-clock µs of the capture origin
	base      u64 // elapsed µs at the last epoch re-anchor
	id_base   u32 // GLOBAL fb id of this partition's first handler (+ local idx)
	budget_us u32 // overrun trigger threshold; 0 = no trigger
	fb_count  u32 // handlers dispatched (a loop can read this to bracket a busy span)
}

// capture wires a Capture to this module's ring — install it with
// `sched.set_trace_hook(trace.fb_hook, &cap)` on the thread that runs the handlers.
// Single-writer: the hook pushes and the module reads on the same thread.
pub fn (mut m TraceModule) capture(id_base u32, budget_us u32, now_us u64) Capture {
	return Capture{
		buf:       &m.buf
		start:     now_us
		id_base:   id_base
		budget_us: budget_us
	}
}

// fb_hook records one handler dispatch: an fb record with the elapsed-µs start (u24, epoch
// re-anchored before it wraps) and the clamped duration; over budget it flags the record and
// freezes the ring (the flight-recorder trigger).
pub fn fb_hook(ctx voidptr, idx int, start_us u64, dt_us u64) {
	mut t := unsafe { &Capture(ctx) }
	t.fb_count++
	elapsed := start_us - t.start
	if elapsed - t.base > 0x00ff_ffff { // u24 start_us would wrap -> re-anchor
		t.base = elapsed
		t.buf.push(new_epoch(u32(elapsed)))
	}
	mut dt := dt_us
	mut flags := u8(0)
	if dt > 0xFFFF { // clamp to the u16 field, and mark it as saturated
		dt = 0xFFFF
		flags |= flag_saturated
	}
	if t.budget_us > 0 && dt_us > t.budget_us {
		flags |= flag_overran
	}
	t.buf.push(new_fb(u16(t.id_base + u32(idx)), flags, u32(elapsed - t.base), u16(dt)))
	if t.budget_us > 0 && dt_us > t.budget_us && t.buf.state() == .capturing {
		t.buf.trigger()
	}
}
