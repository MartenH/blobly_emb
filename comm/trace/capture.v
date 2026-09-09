module trace

// The shared freeze cell is written by whichever core trips and cleared by the owner, so its
// accesses go through atomics — a plain load can be hoisted out of the hook by an optimising
// build and a plain store reordered past the ring trigger, and "aligned is single-copy atomic"
// says nothing about either. The operations are V's OWN portable atomic ABI
// (sync.stdatomic's C.atomic_load_u32 / C.atomic_store_u32, seq_cst — carried by V's
// compiler-compat headers for every C backend V supports), not a compiler-private symbol, so
// this layer stays platform-independent (codex #271 r5). Lock-free inline on host and
// ARMv7-M; the import exists to bring that header in — nothing else of the module is used.
import sync.stdatomic as _

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
	// Cross-core freeze (docs/trace-multicore.md §3), caller-owned like `buf`: a shared cell every
	// traced core points at. Whichever ring trips its budget RAISES it, and every hook OBSERVES it
	// per dispatch, so the peer stops within one handler of the event rather than at the end of a
	// scheduler pass — a peer with more due handlers than its retained pre-window would otherwise
	// overwrite the triggering instant before it ever looked (codex #271 r2). nil = no peer.
	// Retired by TraceModule on a host arm/start/reset (set_freeze), never here.
	freeze &u32 = unsafe { nil }
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
	// The capturing test is taken AT ENTRY — before EITHER push below. Both can retire the
	// ring mid-hook: the FB record can fill a oneshot's final slot, and so can the epoch
	// re-anchor a u24 wrap inserts first (codex #271 r4+r6) — judged after, the overrun that
	// did it read as not-a-trip and the peer was never told.
	was_capturing := t.buf.state() == .capturing
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
	// ONE over-budget predicate for both the record flag and the trigger, so they cannot
	// drift apart under a future edit to either.
	over := t.budget_us > 0 && dt_us > t.budget_us
	if over {
		flags |= flag_overran
	}
	t.buf.push(new_fb(u16(t.id_base + u32(idx)), flags, u32(elapsed - t.base), u16(dt)))
	// A trip is an overrun ON A CAPTURING RING. A ring the host already stopped is not
	// tripping: raising the shared freeze for it would hand a phantom freeze_trigger to a
	// still-capturing peer after a per-core stop.
	mut tripped := false
	if over && was_capturing {
		// trip() reports whether the trigger actually claimed the ring — a host stop landing
		// inside this very hook wins instead, and then no freeze is raised for it either.
		tripped = t.buf.trip()
	}
	t.sync_freeze(tripped)
}

// sync_freeze raises the shared cross-core freeze when THIS ring tripped, and honours a peer that
// already did. Called from the hook — once per dispatch — because that is the resolution the
// coherence claim needs: observing between whole scheduler passes lets a busy peer overwrite the
// triggering instant before it looks. Idempotent in both directions (trigger() is a no-op once a
// ring stops capturing), and a no-op entirely when no peer cell was wired.
//
// Memory model: the same story as osal.scratch — an aligned 32-bit store/load is single-copy
// atomic, the values are single flags (0/1), and a torn read is impossible; raising is done only
// by a ring that actually tripped and clearing only by the module on a host re-arm, so the one
// race that exists (a clear crossing a fresh trip) resolves to one of the two legitimate orders.
// This capture shape is the HOST multicore runner's (threads on one address space); the ThreadX
// two-core path shares state through the board's xcore window instead, not through this cell.
@[inline]
fn (mut t Capture) sync_freeze(this_ring_tripped bool) {
	if t.freeze == unsafe { nil } {
		return
	}
	if this_ring_tripped {
		C.atomic_store_u32(voidptr(t.freeze), 1)
		return
	}
	if C.atomic_load_u32(voidptr(t.freeze)) != 0 {
		t.buf.trigger()
	}
}

// note_thread records ONE busy span of a thread that dispatches no FB handlers — the COM bridge
// (P3b, docs/trace-multicore.md §4.1), whose work is codec/ISO-TP drain rather than handlers, so
// fb_hook never fires for it and its lane would otherwise be empty.
//
// Same epoch discipline as fb_hook, and for the same reason: start_us is a u24 of elapsed µs, so
// the ring must be re-anchored before it wraps or every later record decodes against a lost base.
// Duplicated deliberately rather than factored — fb_hook is called from the Loom's hook signature
// and this from a plain loop, and collapsing them would mean a shared mutable helper on the one
// path that must stay allocation- and branch-free.
pub fn (mut t Capture) note_thread(tid u16, reason u8, start_us u64, dt_us u64) {
	// The same discipline as fb_hook, span for record: the capturing test at ENTRY (either
	// push below can retire the ring mid-call), one over-budget predicate, trip() for the
	// stop-beats-trigger race, and the shared freeze raised/observed per span — the bridge is
	// a first-class traced entity, so it participates in the system-wide freeze like any core.
	was_capturing := t.buf.state() == .capturing
	elapsed := start_us - t.start
	if elapsed - t.base > 0x00ff_ffff { // u24 start_us would wrap -> re-anchor
		t.base = elapsed
		t.buf.push(new_epoch(u32(elapsed)))
	}
	mut dt := dt_us
	if dt > 0xFFFF {
		dt = 0xFFFF // clamp to the u16 field; a span this long is already an anomaly
	}
	t.buf.push(new_thread(tid, reason, u32(elapsed - t.base), u16(dt)))
	over := t.budget_us > 0 && dt_us > t.budget_us
	mut tripped := false
	if over && was_capturing {
		tripped = t.buf.trip() // a drain cycle over budget freezes this ring, like an overrunning handler
	}
	t.sync_freeze(tripped)
}

// thread_hook is note_thread as a Loom trace hook — installed by a partition whose scheduled
// work is a platform drain rather than FB handlers (the COM bridge owner, #191 P3b). The hook's
// idx is ignored: every dispatch is the same entity, the thread the capture's id_base names.
pub fn thread_hook(ctx voidptr, idx int, start_us u64, dt_us u64) {
	mut t := unsafe { &Capture(ctx) }
	t.fb_count++
	t.note_thread(u16(t.id_base), reason_yield, start_us, dt_us)
}
