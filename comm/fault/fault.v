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
// wraps only if 32767 clears pass without one report from the producer — a producer that silent is
// dead, and the generation then stops advancing rather than come round to a stale report's.
//
// Suppression (0x85 off) is enforced HERE, where readings are consumed: while off, the baselines
// follow the counters and nothing changes status; the first reading after "on" is a baseline only.
// So nothing is recorded after a positive "off" and nothing produced during suppression is applied
// after "on" — the accepted cost being that a qualification in the pass on either side of the
// boundary is not recorded either (§7, R4). If an operation cycle began while off, "on" resets that
// cycle's status bits, which the frozen byte still carried from the previous one.
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

// Control is the comm-thread -> producer cell: the clear generation each fault must apply.
pub struct Control {
pub mut:
	gen [max_per_producer]u16
}

// Debounce runs on the producing thread, once per dispatch, right after the handler. Counter-based
// (time_based = false): fail_thr failed results in a row-ish (the counter moves +1 per failed, -1
// per passed) qualify failed, pass_thr qualify passed. Time-based: fail_thr / pass_thr µs of
// continuous failed / passed results. Disabled (an enable condition is false): nothing counts.
pub struct Debounce {
pub mut:
	time_based bool
	fail_thr   u32
	pass_thr   u32
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
		fthr := thr(d.fail_thr)
		pthr := -thr(d.pass_thr)
		if r == .failed {
			d.count = if d.count < 0 { 1 } else if d.count < fthr { d.count + 1 } else { fthr }
		} else {
			d.count = if d.count > 0 { -1 } else if d.count > pthr { d.count - 1 } else { pthr }
		}
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

// apply resets the debounce for a new clear generation and echoes it (a no-op for the current one).
pub fn (mut d Debounce) apply(gen u16) {
	if gen == d.rep.gen {
		return
	}
	d.count = 0
	d.since = 0
	d.run = .not_tested
	d.rep = Report{
		gen: gen
	}
}

// Slot is one configured DTC in the fault memory.
pub struct Slot {
pub mut:
	dtc     u32 // 3-byte DTC (ISO 14229-1 D.1)
	confirm u8  // failed operation cycles to confirm (0 = 1)
	aging   u8  // passing cycles before a confirmed DTC ages out (0 = never)
	// runtime
	status        u8
	occurrence    u16 // saturating
	failed_cycles u8  // saturating
	aging_count   u8
	failed_cycle  bool // failed in the current cycle (already counted)
	tested_cycle  bool // a test completed in the current cycle — runtime state, so a status byte
	// frozen by 0x85 across a boundary is never read as this cycle's result
	gen      u16  // the clear generation the producer must apply — fresh for every clear
	seen_gen u16  // the generation of the producer's latest report, whatever it was (wrap guard)
	rebase   bool // the next report only sets the baselines (0x85 just turned on)
	base_seen     bool // a Report of `gen` has been consumed: the baselines are valid
	base_fails    u16
	base_tests    u16
}

// Memory is the node's fault memory — one writer, the comm thread (D2). RAM only in R4;
// persistence is R6.
pub struct Memory {
pub mut:
	slots        [max_faults]Slot
	n            int
	setting_off  bool // 0x85 off
	cycle_active bool
	boundary_off bool // an operation cycle began while 0x85 was off
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
		m.slots[i].rebase = false
		m.slots[i].gen = 0
		m.slots[i].base_seen = false
	}
	m.setting_off = false
	m.cycle_active = false
	m.boundary_off = false
}

// consume applies slot i's latest Report. Call every owner pass for every fault.
pub fn (mut m Memory) consume(i int, r Report) {
	if i < 0 || i >= m.n {
		return
	}
	mut s := &m.slots[i]
	s.seen_gen = r.gen
	if r.gen != s.gen {
		return // the producer has not applied the latest clear yet: an older generation counts for nothing
	}
	df := if s.base_seen { r.fails - s.base_fails } else { r.fails }
	dt := if s.base_seen { r.tests - s.base_tests } else { r.tests }
	s.base_fails = r.fails
	s.base_tests = r.tests
	s.base_seen = true
	if s.rebase {
		s.rebase = false
		return // the first reading after 0x85 on: whatever it carries was produced while off
	}
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

// cycle_end closes it: a DTC tested and not failed this cycle is no longer pending, and a confirmed
// one ages toward removal.
pub fn (mut m Memory) cycle_end() {
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
	}
}

// clear is 0x14: group 0xFFFFFF clears every DTC, anything else the one DTC it names. Returns false
// for an unknown DTC (the server answers 0x31). Each cleared slot's generation moves on, so the
// producer resets and its older reports are ignored.
pub fn (mut m Memory) clear(group u32) bool {
	mut hit := false
	for i in 0 .. m.n {
		if group != 0xFFFFFF && m.slots[i].dtc != group {
			continue
		}
		hit = true
		mut s := &m.slots[i]
		s.status = status_cleared
		s.occurrence = 0
		s.failed_cycles = 0
		s.aging_count = 0
		s.failed_cycle = false
		s.tested_cycle = false
		if u16(s.gen - s.seen_gen) < 0x7FFF {
			s.gen++ // fresh: no report produced before this clear can carry it
		}
		s.base_seen = false
	}
	return hit
}

// control_gen is the generation fault i's producer must apply (the owner copies it into the
// producer's Control cell).
pub fn (m Memory) control_gen(i int) u16 {
	return m.slots[i].gen
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

fn ops_clear(ctx voidptr, group u32) bool {
	mut m := unsafe { &Memory(ctx) }
	return m.clear(group)
}

fn ops_setting(ctx voidptr, on bool) {
	mut m := unsafe { &Memory(ctx) }
	m.set_setting(on)
}

// set_setting is 0x85. Turning it back on makes each slot's next reading a baseline only (it may
// carry results produced while off), and — when an operation cycle began while off — resets that
// cycle's status bits, which the frozen byte still carried from the previous cycle.
pub fn (mut m Memory) set_setting(on bool) {
	if on && m.setting_off {
		for i in 0 .. m.n {
			m.slots[i].rebase = true
			if m.boundary_off && m.cycle_active {
				m.slots[i].status = (m.slots[i].status & ~test_failed_this_cycle) | not_completed_this_cycle
			}
		}
		m.boundary_off = false
	}
	m.setting_off = !on
}
