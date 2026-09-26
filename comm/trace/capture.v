module trace

// The shared freeze cells are written from more than one thread, so every access goes through
// atomics — a plain load can be hoisted out of the hook by an optimising build and a plain store
// reordered past the ring trigger, and "aligned is single-copy atomic" says nothing about either.
// The operations are V's OWN portable atomic ABI (sync.stdatomic's C.atomic_load_u32 /
// C.atomic_store_u32 / C.atomic_compare_exchange_strong_u32, seq_cst — carried by V's
// compiler-compat headers for every C backend V supports), not a compiler-private symbol, so this
// layer stays platform-independent (codex #271 r5). Lock-free inline on host and ARMv7-M; the
// import exists to bring that header in — nothing else of the module is used.
import sync.stdatomic as _

// FreezeSync is the system-wide freeze of a multi-core trace (docs/trace-multicore.md §3), made
// GENERATION-AWARE (#273). Caller-owned (the generated runner keeps it in run(), which outlives
// both threads); every traced core's Capture and the dump owner's TraceModule point at it.
//
//   word   generation << 1 | raised. ONE writer of the generation: the owner, on a host re-arm
//          (TraceModule.bump). A hook RAISES by compare-and-swap from `gen << 1` to `gen << 1 | 1`
//          with its OWN window's generation, so a trip in a window a re-arm just ended fails the
//          swap instead of freezing the fresh one; and a re-arm RETIRES by storing the next
//          generation, so no check-then-clear is left to race a raise. Those were the two
//          orderings the flag cell of #271 could not close.
//   rearm  the newest generation whose re-arm ADDRESSED the satellite. The satellite restarts its
//          OWN ring when it adopts a generation at or past this — on its own thread, at hook
//          entry, so no dispatch can overlap the restart. (The owner used to restart the peer's
//          ring cross-thread; that overlap was where a stale raise came from.)
//   ack    the newest generation the satellite has adopted. rearm > ack = a restart the satellite
//          has not performed yet, and the owner refuses stop/dump against it until it has.
//
// Generations are u32 and only ever grow by one per re-arm; wrap needs 2^31 re-arms.
pub struct FreezeSync {
mut:
	word  u32
	rearm u32
	ack   u32
}

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
	// Cross-core freeze (docs/trace-multicore.md §3), caller-owned like `buf`: the FreezeSync every
	// traced core points at. Whichever ring trips its budget RAISES it, and every hook OBSERVES it
	// per dispatch, so the peer stops within one handler of the event rather than at the end of a
	// scheduler pass — a peer with more due handlers than its retained pre-window would otherwise
	// overwrite the triggering instant before it ever looked (codex #271 r2). nil = no peer.
	freeze &FreezeSync = unsafe { nil }
	// The generation of the window this ring is recording — adopted at hook entry (adopt), so every
	// raise and every observation is judged against the window it actually belongs to.
	gen u32
	// The SATELLITE's capture restarts its own ring when a re-arm addresses it (FreezeSync.rearm);
	// the owner's ring is restarted by the owner's own command path, on its own thread.
	satellite bool
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
	t.adopt() // FIRST: a pending re-arm restarts this ring before anything is recorded into it
	// The capturing test is taken AT ENTRY — before EITHER push below. Both can retire the
	// ring mid-hook: the FB record can fill a oneshot's final slot, and so can the epoch
	// re-anchor a u24 wrap inserts first (codex #271 r4+r6) — judged after, the overrun that
	// did it read as not-a-trip and the peer was never told.
	was_capturing := t.buf.state() == .capturing
	elapsed := start_us - t.start
	t.anchor(elapsed, was_capturing)
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

// anchor keeps the capture's u24 stamp window aligned with the RING, and is the one place
// either hook re-anchors. Two cases, both of which left a lane misread:
//   * the stamp would overflow the u24 field — the original wrap case;
//   * the ring was re-armed under this capture. arm/start/reset empties the buffer and drops
//     its carried epoch prefix, while `base` stayed where the last window left it, so the first
//     record of the new window was written as `elapsed - base` with no epoch to anchor it and
//     the decoder placed the lane at zero — a shift of ~16.7 s per elapsed wrap (codex #274 r2).
// And never on a ring that is not capturing: push() discards the epoch there, so advancing the
// base would silently desynchronise it from what the ring actually holds.
@[inline]
fn (mut t Capture) anchor(elapsed u64, capturing bool) {
	if !capturing {
		return
	}
	if elapsed - t.base > 0x00ff_ffff || (t.buf.used() == 0 && t.base != 0) {
		t.base = elapsed
		t.buf.push(new_epoch(u32(elapsed)))
	}
}

// adopt brings this capture onto the system's current generation, at hook ENTRY — before the
// capturing test and before any record — so everything the hook then does belongs to one window.
// A satellite whose re-arm is pending restarts its OWN ring here: the restart runs on the thread
// that writes the ring, so no dispatch can straddle it. It acknowledges every generation it adopts;
// the owner reads that to know the restart has happened (FreezeSync.ack).
@[inline]
fn (mut t Capture) adopt() {
	if t.freeze == unsafe { nil } {
		return
	}
	g := C.atomic_load_u32(voidptr(&t.freeze.word)) >> 1
	if g == t.gen {
		return
	}
	if t.satellite {
		// `>` not `==`: a later re-arm that did not address the satellite must not swallow an
		// earlier one that did and was never performed.
		if C.atomic_load_u32(voidptr(&t.freeze.rearm)) > t.gen {
			t.buf.start()
		}
	}
	t.gen = g
	if t.satellite {
		C.atomic_store_u32(voidptr(&t.freeze.ack), g)
	}
}

// sync_freeze raises the system freeze when THIS ring tripped, and honours a peer that already did
// — both in THIS capture's generation. Called from the hook, once per dispatch: observing between
// whole scheduler passes lets a busy peer overwrite the triggering instant before it looks.
//
// The raise is a compare-and-swap from `gen << 1` to `gen << 1 | 1`, so it lands only while the
// system is still in this window's generation. A re-arm that bumped the generation between this
// hook's adopt() and here — the window being ended by the host — makes the swap fail, and the
// trip freezes only the ring it happened in (whose record carries flag_overran either way). An
// observation likewise honours only a raise of this capture's own generation. A no-op entirely
// when no peer was wired.
@[inline]
fn (mut t Capture) sync_freeze(this_ring_tripped bool) {
	if t.freeze == unsafe { nil } {
		return
	}
	if this_ring_tripped {
		mut expected := t.gen << 1
		C.atomic_compare_exchange_strong_u32(voidptr(&t.freeze.word), &expected, (t.gen << 1) | 1)
		return
	}
	if C.atomic_load_u32(voidptr(&t.freeze.word)) == ((t.gen << 1) | 1) {
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
	t.adopt()
	was_capturing := t.buf.state() == .capturing
	elapsed := start_us - t.start
	t.anchor(elapsed, was_capturing)
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
