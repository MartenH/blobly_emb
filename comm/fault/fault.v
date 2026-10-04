module fault

// Faults and the fault memory (docs/diagnostics.md §3.3, decisions D1/D2/D3), no-alloc.
//
// Two halves on two threads, joined by ordinary last-value IOC cells:
//
//   PRODUCER (the FB's thread) — the FB writes a pre-debounce TestResult each dispatch; the
//   generated Loom runs a Debounce per fault right after the handler. What crosses to the comm
//   thread is a Report: the debounced state plus MONOTONIC counters (D1), so a consumer that reads
//   slower than the producer writes still sees every qualification as a counter delta.
//
//   CONSUMER (the comm thread, D2) — the Memory turns counter deltas into the ISO 14229-1 status
//   byte per DTC, runs the operation cycle (D3: its start/end come from the owner), clears, and
//   0x85 suppression, and answers 0x19 / 0x14 / 0x85 through uds.FaultOps.
//
// A clear must reach the producer, or its still-failed debounce would re-report at once: the
// Memory bumps the fault's GENERATION, the owner carries it back in a control cell, the producer
// resets its debounce and counters and echoes it in `gen`. A Report of any other generation is
// ignored — an old-generation failure can never recreate a cleared DTC (§7, R4).
//
// Every clear gets a FRESH generation (u16), so no report produced before it can ever count. It
// could wrap only after 32767 generations without one report from the producer — a producer that
// silent is dead — and there a clear is REFUSED (0x22) rather than reuse a generation.
//
// Suppression (0x85) uses the same generation. While off, nothing changes status (the baselines
// follow the counters). Turning it on starts a fresh generation, exactly as a clear does but
// without touching the status: the producer resets its debounce, so neither a report produced
// while off NOR the debounce state accumulated while off — a counter saturated by a failure the
// off window saw — is applied after "on" (#364). A generation renewed while the status shows
// testFailed is `held`: the producer starts it failed, so that failure re-qualifying is not a new
// occurrence, and only the producer, which sees the order of its own results, decides that. The
// accepted cost: a result held across "on", failed or passed, completes again only once it
// debounces from zero (§7, R4). If no fresh generation is free at "on", the slot's RESULTS stay
// suppressed (its cycle bits move as any slot's) until the producer's report frees one; what that
// producer qualified meanwhile is lost with them. If an operation cycle began while off, "on" resets that
// cycle's status bits, which the frozen byte still carried from the previous one.
//
// Beyond the status byte (R6b): a SNAPSHOT (freeze frame) per DTC that declares one, captured from
// the server's own DIDs at the failure that allocates it (entry.v), the EXTENDED DATA records
// (occurrence, aging and failed-cycle counters), DISPLACEMENT when the snapshot entries are full,
// and PERSISTENCE through an injected store (persist.v) — the journal on a ThreadX target.
//
// No field defaults anywhere (the _vinit rule): the owner calls init / configures explicitly.

import comm.uds

pub const max_faults = 32 // per fault memory (one per node: one diagnostic server)
pub const max_per_producer = 8 // faults one producing thread may own: its Report cell is bounded

// ISO 14229-1 DTC status bits.
pub const test_failed = u8(0x01)
pub const test_failed_this_cycle = u8(0x02)
pub const pending = u8(0x04)
pub const confirmed = u8(0x08)
pub const not_completed_since_clear = u8(0x10)
pub const failed_since_clear = u8(0x20)
pub const not_completed_this_cycle = u8(0x40)
pub const warning_indicator = u8(0x80)

// The bits this memory maintains (warningIndicatorRequested is not supported: no lamp is wired).
pub const availability_mask = u8(0x7F)

// The status of a DTC after a clear, and at power-on: nothing completed yet.
pub const status_cleared = not_completed_since_clear | not_completed_this_cycle

// TestResult is what an FB writes to its fault port each dispatch — pre-debounce. Untouched reads
// not_tested (the zero value).
pub enum TestResult as u8 {
	not_tested
	passed
	failed
}

// Report crosses the producer -> comm-thread cell, one per fault. Counters wrap; the Memory diffs.
pub struct Report {
pub mut:
	gen    u16  // the clear generation the producer has applied
	failed bool // the debounced state
	fails  u16  // qualifications into failed (occurrences)
	tests  u16  // results that left the debounce at a threshold (the test "completed")
}

// Reports is one producing thread's cell (<= the 64-byte IOC payload).
pub struct Reports {
pub mut:
	r [max_per_producer]Report
}

// Control is the comm-thread -> producer cell: the generation each fault must apply, and whether
// that generation starts failed (`held`: the memory still shows the failure a 0x85 on restarted).
pub struct Control {
pub mut:
	gen  [max_per_producer]u16
	held [max_per_producer]bool
}

// Debounce runs on the producing thread, once per dispatch, right after the handler.
//
// Counter-based (time_based = false), shaped like AUTOSAR DEM's counter debounce: one counter moves
// up by `inc` per failed result and down by `dec` per passed one, and qualifies failed at +fail_thr,
// passed at -pass_thr. By default it ACCUMULATES across reversals, so an intermittent fault (failing
// 2 of every 3 dispatches) still drifts up and qualifies; `jump` resets it to 0 on a reversal
// instead ("fail_thr in a row"). Asymmetric steps (inc 2, dec 1) fail fast and heal slowly.
// Time-based: fail_thr / pass_thr µs of continuous failed / passed results.
// Disabled (an enable condition is false) or not tested: nothing counts.
pub struct Debounce {
pub mut:
	time_based bool
	fail_thr   u32
	pass_thr   u32
	inc        u32  // counter step per failed result (0 = 1)
	dec        u32  // counter step per passed result (0 = 1)
	jump       bool // reset to 0 when the direction reverses
	count      i32 // counter-based position, -pass_thr .. +fail_thr
	since      u64 // time-based: when the current run of equal results began
	run        TestResult
	rep        Report
}

// step feeds one dispatch's result. It returns nothing; the Report in `rep` is what the owner
// publishes.
pub fn (mut d Debounce) step(r TestResult, now u64, enabled bool) {
	if !enabled || r == .not_tested {
		// a gap: the counter holds where it is, and a time-based run restarts — a condition that
		// returns never qualifies on the time held before it went away (docs/diagnostics.md §3.3)
		d.run = .not_tested
		return
	}
	mut at_fail := false
	mut at_pass := false
	if d.time_based {
		if r != d.run {
			d.run = r
			d.since = now
		}
		held := now - d.since
		at_fail = r == .failed && held >= u64(d.fail_thr)
		at_pass = r == .passed && held >= u64(d.pass_thr)
	} else {
		fthr := i64(thr(d.fail_thr))
		pthr := -i64(thr(d.pass_thr))
		mut c := i64(d.count)
		if r == .failed {
			if d.jump && c < 0 {
				c = 0
			}
			c += i64(thr(d.inc))
			if c > fthr {
				c = fthr
			}
		} else {
			if d.jump && c > 0 {
				c = 0
			}
			c -= i64(thr(d.dec))
			if c < pthr {
				c = pthr
			}
		}
		d.count = i32(c)
		at_fail = d.count >= fthr
		at_pass = d.count <= pthr
	}
	if at_fail {
		if !d.rep.failed {
			d.rep.failed = true
			d.rep.fails++
		}
		d.rep.tests++
	} else if at_pass {
		d.rep.failed = false
		d.rep.tests++
	}
}

// apply resets the debounce for a new generation and echoes it (a no-op for the current one). A
// `held` generation starts in the failed state the memory shows, so the failure re-qualifying is
// not a new occurrence, while a pass and then a failure is — the producer sees that order, the
// memory reading its counters later does not.
pub fn (mut d Debounce) apply(gen u16, held bool) {
	if gen == d.rep.gen {
		return
	}
	d.count = 0
	d.since = 0
	d.run = .not_tested
	d.rep = Report{
		gen:    gen
		failed: held
	}
}

// Slot is one configured DTC in the fault memory.
pub struct Slot {
pub mut:
	dtc     u32 // 3-byte DTC (ISO 14229-1 D.1)
	confirm u8  // failed operation cycles to confirm (0 = 1)
	aging   u8  // passing cycles before a confirmed DTC ages out (0 = never)
	// the snapshot (entry.v): the DIDs captured at the failure that allocates an entry, each with
	// its fixed size; nfreeze == 0 = this DTC keeps no snapshot
	freeze     [max_freeze]u16
	freeze_len [max_freeze]u8
	nfreeze    int
	priority   u8  // displacement: 1 = the most important .. 255 (0 reads as 255)
	snap_id    u16 // the snapshot's two blocks in the store, A and B (persist.v)
	snap_id_b  u16
	// runtime
	status        u8
	occurrence    u16 // saturating
	failed_cycles u8  // saturating
	aging_count   u8
	failed_cycle  bool // failed in the current cycle (already counted)
	tested_cycle  bool // a test completed in the current cycle — runtime state, so a status byte
	// frozen by 0x85 across a boundary is never read as this cycle's result
	gen        u16  // the generation the producer must apply — fresh for every clear and 0x85 on
	seen_gen   u16  // the generation of the producer's latest report, whatever it was (wrap guard)
	base_seen  bool // a Report of `gen` has been consumed: the baselines are valid
	base_fails u16
	base_tests u16
	held       bool // `gen` starts failed: renewed by 0x85 on while the status showed testFailed
	wait_gen   bool // no fresh generation was free at 0x85 on: results suppressed until one is
	entry      int  // the snapshot entry this DTC holds, index + 1; 0 = none
	snap_due   bool // an occurrence wants a snapshot captured (capture)
	// persistence (persist.v): what the store holds for this DTC
	claim    u8   // which snapshot block the COMMITTED image claims: 0 none, 1 A, 2 B
	claim_ok bool // ... and it holds that snapshot (committed from one, or read back at restore)
	live  [2]bool // blocks A / B hold a snapshot (not a tombstone or nothing)
}

// Memory is the node's fault memory — one writer, the comm thread (D2). Its receivers are all
// `&Memory` / `mut Memory`: it is several KB, and a value receiver would copy it onto a 4 KB stack.
pub struct Memory {
pub mut:
	slots        [max_faults]Slot
	n            int
	setting_off  bool // 0x85 off
	cycle_active bool
	boundary_off bool // an operation cycle began while 0x85 was off
	ending       bool // the cycle's end is requested and waits for the producers (end_cycle_after)
	end_at       u64
	// snapshot entries (entry.v): `cap` of them, held by the DTCs that failed most importantly
	entries    [max_entries]Entry
	cap        int
	next_stamp u32 // the allocation order: older entries are displaced first among equals
	displaced  u32 // snapshots displaced since power-on (observability)
	// persistence (persist.v): nil store = RAM only
	store    Store
	img      [max_image]u8 // the status image the store holds (img_len 0 = none known)
	img_len  int
	scratch  [max_block]u8 // an image or a snapshot block being built
	retry_at u64 // a refused write is retried no sooner than this
	wrote    int  // writes the last persist / clear made (the owner re-lays its clean marker)
	refused  bool // the store refused a write since the last persist, a 0x14's included (observability)
	clear_refused bool // a 0x14 the store refused, carried into the next persist's `refused`
}

// init sets every configured slot to the power-on status. Call after filling dtc / confirm / aging.
pub fn (mut m Memory) init() {
	for i in 0 .. m.n {
		m.slots[i].status = status_cleared
		m.slots[i].occurrence = 0
		m.slots[i].failed_cycles = 0
		m.slots[i].aging_count = 0
		m.slots[i].failed_cycle = false
		m.slots[i].tested_cycle = false
		m.slots[i].seen_gen = 0
		m.slots[i].gen = 0
		m.slots[i].base_seen = false
		m.slots[i].held = false
		m.slots[i].wait_gen = false
		m.slots[i].entry = 0
		m.slots[i].snap_due = false
		m.slots[i].claim = 0
		m.slots[i].claim_ok = false
		m.slots[i].live[0] = false
		m.slots[i].live[1] = false
	}
	for k in 0 .. max_entries {
		m.entries[k].used = false
		m.entries[k].durable = false
	}
	m.setting_off = false
	m.cycle_active = false
	m.boundary_off = false
	m.ending = false
	m.end_at = 0
	m.next_stamp = 1
	m.displaced = 0
	m.img_len = 0
	m.retry_at = 0
	m.wrote = 0
	m.refused = false
	m.clear_refused = false
}

// consume applies slot i's latest Report. Call every owner pass for every fault.
pub fn (mut m Memory) consume(i int, r Report) {
	if i < 0 || i >= m.n {
		return
	}
	mut s := &m.slots[i]
	s.seen_gen = r.gen
	if s.wait_gen {
		// "on" found no fresh generation; this report may carry the old one from the off window.
		// Renewed only while on: an "off" in between leaves it to the next "on" to renew once.
		if !m.setting_off && s.can_renew() {
			s.wait_gen = false
			s.renew(s.status & test_failed != 0)
		}
		return
	}
	if r.gen != s.gen {
		return // the producer has not applied the latest clear yet: an older generation counts for nothing
	}
	df := if s.base_seen { r.fails - s.base_fails } else { r.fails }
	dt := if s.base_seen { r.tests - s.base_tests } else { r.tests }
	s.base_fails = r.fails
	s.base_tests = r.tests
	s.base_seen = true
	if m.setting_off || !m.cycle_active || (df == 0 && dt == 0) {
		return // suppressed, or outside an operation cycle: the baselines follow, the status does not
	}
	if dt > 0 {
		s.tested_cycle = true
		s.status &= ~(not_completed_since_clear | not_completed_this_cycle)
		if r.failed {
			s.status |= test_failed
		} else {
			s.status &= ~test_failed
		}
	}
	if df > 0 || (r.failed && dt > 0) {
		s.status |= test_failed_this_cycle | pending | failed_since_clear
		if df > 0 {
			s.occurrence = sat16(s.occurrence, df)
			if s.nfreeze > 0 && s.entry == 0 {
				s.snap_due = true // captured by the owner from the server's DIDs (capture)
			}
		}
		if !s.failed_cycle {
			s.failed_cycle = true
			if s.failed_cycles < 255 {
				s.failed_cycles++
			}
			if s.failed_cycles >= (if s.confirm == 0 { u8(1) } else { s.confirm }) {
				s.status |= confirmed
			}
		}
		s.aging_count = 0
	}
}

// cycle_start begins an operation cycle (D3: NM wake, or the declared cycle signal rising). One
// still open is ended first, so its pending / aging bookkeeping is never skipped. While 0x85 has
// DTC setting off no status bit changes — the cycle's own bits included.
pub fn (mut m Memory) cycle_start() {
	m.ending = false // an end still waiting for its grace happens now
	if m.cycle_active {
		m.cycle_end()
	}
	if m.setting_off {
		m.boundary_off = true
	}
	for i in 0 .. m.n {
		if !m.setting_off {
			m.slots[i].status = (m.slots[i].status & ~test_failed_this_cycle) | not_completed_this_cycle
		}
		m.slots[i].failed_cycle = false
		m.slots[i].tested_cycle = false
	}
	m.cycle_active = true
}

// end_cycle_after requests the operation cycle's end `grace_us` from `now`, the cycle-end barrier
// (docs/diagnostics.md §7): a producer's dispatch that began before the end was decided — NM going
// to sleep — publishes its report within one of its periods, and a report the owner reads only
// after cycle_end would count for nothing, the qualification in it lost from the cycle it belongs
// to and from the store. So the cycle stays open for the grace (at least the longest period of a
// fault-owning handler), the owner consuming as usual, and ends at cycle_end_due — after one more
// consume. Nothing ends while no cycle is open.
pub fn (mut m Memory) end_cycle_after(now u64, grace_us u64) {
	if !m.cycle_active || m.ending {
		return
	}
	m.ending = true
	m.end_at = now + grace_us
}

// cycle_end_due: a requested end's grace has passed — the owner consumes the producers' latest
// reports, then calls cycle_end.
pub fn (m &Memory) cycle_end_due(now u64) bool {
	return m.ending && now >= m.end_at
}

// cycle_end closes it: a DTC tested and not failed this cycle is no longer pending, and a confirmed
// one ages toward removal.
pub fn (mut m Memory) cycle_end() {
	m.ending = false
	if !m.cycle_active {
		return
	}
	m.cycle_active = false
	if m.setting_off {
		return // 0x85 off: the status is frozen, the cycle still ends
	}
	for i in 0 .. m.n {
		mut s := &m.slots[i]
		if s.tested_cycle && !s.failed_cycle {
			s.status &= ~pending
			if s.status & confirmed == 0 {
				s.failed_cycles = 0 // a passing cycle breaks a run toward confirmation
			} else if s.aging > 0 {
				s.aging_count++
				if s.aging_count >= s.aging {
					s.status &= ~confirmed // aged out: confirmation starts over
					s.aging_count = 0
					s.failed_cycles = 0
				}
			}
		}
		if s.entry != 0 && s.status & (pending | confirmed) == 0 {
			m.free_entry(i) // healed before confirming, or aged out: nothing left the snapshot explains
		}
	}
}

// clear is 0x14: group 0xFFFFFF clears every DTC, anything else the one DTC it names. Each cleared
// slot's generation moves on, so the producer resets and its older reports are ignored, and its
// snapshot entry is freed.
// Returns the negative response code, 0 = cleared: 0x31 for an unknown DTC, 0x22 when a slot's
// producer has left so many clears unacknowledged that no fresh generation can be assigned — then
// NOTHING is cleared, since a clear that reused a generation could let a pre-clear report count —
// and 0x72 when the store refuses the cleared image (nothing is cleared then either).
pub fn (mut m Memory) clear(group u32) u8 {
	mut hit := false
	for i in 0 .. m.n {
		if group != 0xFFFFFF && m.slots[i].dtc != group {
			continue
		}
		hit = true
		if !m.slots[i].can_renew() {
			return 0x22 // conditionsNotCorrect: the producer has been silent for 32767 generations
		}
	}
	if !hit {
		return 0x31 // requestOutOfRange: no such DTC
	}
	// persisted: the cleared image must be durable before anything changes in RAM — a refused
	// write leaves live and durable state as they were, and the tester gets 0x72
	if !m.persist_clear(group) {
		return 0x72 // generalProgrammingFailure
	}
	for i in 0 .. m.n {
		if group != 0xFFFFFF && m.slots[i].dtc != group {
			continue
		}
		mut s := &m.slots[i]
		if s.entry != 0 {
			m.free_entry(i)
		}
		s.snap_due = false
		s.status = status_cleared
		s.occurrence = 0
		s.failed_cycles = 0
		s.aging_count = 0
		s.failed_cycle = false
		s.tested_cycle = false
		s.wait_gen = false // the clear's generation is fresh, and later than any "on"
		s.renew(false)
	}
	return 0
}

// can_renew: a fresh generation is available — one the producer's latest report cannot carry and
// no report it made earlier can come round to (a u16 compared within half its range).
fn (s &Slot) can_renew() bool {
	return u16(s.gen - s.seen_gen) < 0x7FFF
}

// renew moves the slot to a fresh generation: no report produced before it counts, and the
// producer resets its debounce when it applies it, starting failed when `held`. The caller has
// checked can_renew.
fn (mut s Slot) renew(held bool) {
	s.gen++
	s.held = held
	s.base_seen = false
}

// control_gen is the generation fault i's producer must apply (the owner copies it into the
// producer's Control cell).
pub fn (m &Memory) control_gen(i int) u16 {
	return m.slots[i].gen
}

// control_held is whether that generation starts failed (copied beside control_gen).
pub fn (m &Memory) control_held(i int) bool {
	return m.slots[i].held
}

// thr: a counter threshold as i32, at least 1 and at most i32's range (a wrap would qualify at once).
fn thr(t u32) i32 {
	return if t == 0 { 1 } else if t > u32(max_i32) { max_i32 } else { i32(t) }
}

fn sat16(a u16, b u16) u16 {
	s := u32(a) + u32(b)
	return if s > 0xFFFF { u16(0xFFFF) } else { u16(s) }
}

// uds_ops is the seam the diagnostic server answers 0x19 / 0x14 / 0x85 through. `m` must outlive
// the server that holds the ops.
pub fn (mut m Memory) uds_ops() uds.FaultOps {
	return uds.FaultOps{
		ctx:         unsafe { voidptr(&m) }
		count:       ops_count
		entry:       ops_entry
		clear:       ops_clear
		set_setting: ops_setting
		snapshot:    ops_snapshot
		extended:    ops_extended
		ext_records: ext_records
		avail:       availability_mask
	}
}

fn ops_count(ctx voidptr) int {
	m := unsafe { &Memory(ctx) }
	return m.n
}

fn ops_entry(ctx voidptr, i int) u32 {
	m := unsafe { &Memory(ctx) }
	return (m.slots[i].dtc & 0xFFFFFF) << 8 | u32(m.slots[i].status & availability_mask)
}

fn ops_clear(ctx voidptr, group u32) u8 {
	mut m := unsafe { &Memory(ctx) }
	return m.clear(group)
}

fn ops_setting(ctx voidptr, on bool) {
	mut m := unsafe { &Memory(ctx) }
	m.set_setting(on)
}

// set_setting is 0x85. Turning it back on moves every slot to a fresh generation, as a clear does
// but leaving the status: the producer restarts its debounce, so nothing it reported or accumulated
// while off is applied afterwards (#364). A slot showing testFailed gets a `held` generation, so
// the failure re-qualifying after the restart is not a second occurrence. When an operation cycle
// began while off, "on" also resets that cycle's status bits, which the frozen byte still carried
// from the previous cycle.
//
// "On" cannot be refused (a session ending turns it on too). A slot with no fresh generation — its
// producer silent for 32767 of them — waits instead (`wait_gen`): its results stay suppressed, and
// its next report, which frees one, renews it rather than counting. What that producer qualifies
// before it applies the renewed generation is lost: it restarts twice, once on the old generation
// and once on the fresh one — the cost of a producer that had been silent that long.
pub fn (mut m Memory) set_setting(on bool) {
	if on && m.setting_off {
		for i in 0 .. m.n {
			if m.slots[i].can_renew() {
				m.slots[i].wait_gen = false
				m.slots[i].renew(m.slots[i].status & test_failed != 0)
			} else {
				m.slots[i].wait_gen = true
			}
			if m.boundary_off && m.cycle_active {
				m.slots[i].status = (m.slots[i].status & ~test_failed_this_cycle) | not_completed_this_cycle
			}
		}
		m.boundary_off = false
	}
	m.setting_off = !on
}
