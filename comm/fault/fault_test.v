module fault

import comm.uds

// @verifies REQ-DIAG-009 REQ-DIAG-010
// (debounce on the producer with lossless monotonic counters; the ISO 14229-1 status byte through
//  operation cycles, confirmation and aging; clears by generation; 0x85 suppression; 0x19 01/02/0A,
//  0x14 and 0x85 through the diagnostic server.)

fn counter(fail u32, pass u32) Debounce {
	return Debounce{
		fail_thr: fail
		pass_thr: pass
	}
}

fn memory(dtcs []u32) Memory {
	mut m := Memory{}
	for i, d in dtcs {
		m.slots[i].dtc = d
		m.slots[i].confirm = 1
	}
	m.n = dtcs.len
	m.init()
	return m
}

// Counter debounce: fail_thr failed results qualify failed once (one occurrence), each result at
// a threshold counts as a completed test, and a passed run re-qualifies passed.
fn test_counter_debounce_qualifies_once_and_counts_tests() {
	mut d := counter(3, 2)
	d.step(.failed, 0, true)
	d.step(.failed, 0, true)
	assert !d.rep.failed && d.rep.tests == 0
	d.step(.failed, 0, true)
	assert d.rep.failed && d.rep.fails == 1 && d.rep.tests == 1
	d.step(.failed, 0, true)
	assert d.rep.fails == 1 && d.rep.tests == 2, 'a steady failure is one occurrence'
	d.step(.passed, 0, true)
	assert d.rep.failed, 'one pass does not qualify passed'
	d.step(.passed, 0, true)
	assert !d.rep.failed && d.rep.tests == 3
	d.step(.not_tested, 0, true)
	d.step(.failed, 0, false) // enable condition false
	assert d.rep.tests == 3 && d.rep.fails == 1, 'untested / disabled results count for nothing'
}

// Time debounce: the result must hold for the threshold.
fn test_time_debounce() {
	mut d := Debounce{
		time_based: true
		fail_thr:   1000
		pass_thr:   500
	}
	d.step(.failed, 10_000, true)
	d.step(.failed, 10_900, true)
	assert !d.rep.failed
	d.step(.failed, 11_000, true)
	assert d.rep.failed && d.rep.fails == 1
	d.step(.passed, 12_000, true)
	d.step(.passed, 12_499, true)
	assert d.rep.failed
	d.step(.passed, 12_500, true)
	assert !d.rep.failed
}

// Status byte: fail sets TF/TFTOC/PDTC/CDTC(confirm 1)/TFSLC and clears the not-completed bits; a
// cycle ending tested-and-passed clears pending; aging removes confirmed after N such cycles.
fn test_status_through_cycles_confirm_and_aging() {
	mut m := memory([u32(0x523000)])
	m.slots[0].aging = 2
	mut d := counter(1, 1)
	assert m.slots[0].status == status_cleared
	m.cycle_start()
	d.step(.failed, 0, true)
	m.consume(0, d.rep)
	assert m.slots[0].status == test_failed | test_failed_this_cycle | pending | confirmed | failed_since_clear
	assert m.slots[0].occurrence == 1
	d.step(.passed, 0, true)
	m.consume(0, d.rep)
	assert m.slots[0].status & test_failed == 0
	m.cycle_end()
	assert m.slots[0].status & pending != 0, 'failed this cycle: still pending'
	for _ in 0 .. 2 {
		m.cycle_start()
		assert m.slots[0].status & (test_failed_this_cycle | not_completed_this_cycle) == not_completed_this_cycle
		d.step(.passed, 0, true)
		m.consume(0, d.rep)
		m.cycle_end()
		assert m.slots[0].status & pending == 0
	}
	assert m.slots[0].status & confirmed == 0, 'aged out after two passing cycles'
	assert m.slots[0].status & failed_since_clear != 0
}

// A steadily failing test is failing THIS cycle too, though it qualified in the previous one.
fn test_a_steady_failure_counts_in_every_cycle() {
	mut m := memory([u32(1)])
	m.slots[0].confirm = 2
	mut d := counter(1, 1)
	m.cycle_start()
	d.step(.failed, 0, true)
	m.consume(0, d.rep)
	m.cycle_end()
	assert m.slots[0].status & confirmed == 0
	m.cycle_start()
	d.step(.failed, 0, true) // no new occurrence, but a completed failed test
	m.consume(0, d.rep)
	assert m.slots[0].status & (test_failed_this_cycle | confirmed) == test_failed_this_cycle | confirmed
	assert m.slots[0].occurrence == 1
}

// §7 R4: the tested state is lossless — one evaluation followed by not_tested, read once late,
// still completes the test this cycle.
fn test_tested_is_lossless() {
	mut m := memory([u32(1)])
	mut d := counter(1, 1)
	m.cycle_start()
	d.step(.passed, 0, true)
	d.step(.not_tested, 0, true)
	d.step(.not_tested, 0, true)
	m.consume(0, d.rep)
	assert m.slots[0].status & not_completed_this_cycle == 0
}

// §7 R4: a clear makes the prior generation obsolete — the producer publishes a still-failed
// report of the OLD generation once more before it sees the clear; it must not recreate the DTC.
fn test_clear_ignores_old_generation_until_applied() {
	mut m := memory([u32(0x100), u32(0x200)])
	mut d := counter(1, 1)
	m.cycle_start()
	d.step(.failed, 0, true)
	m.consume(0, d.rep)
	assert m.slots[0].status & confirmed != 0
	assert m.clear(0x100)
	assert m.slots[0].status == status_cleared && m.slots[0].occurrence == 0
	d.step(.failed, 0, true) // still the old generation
	m.consume(0, d.rep)
	assert m.slots[0].status == status_cleared, 'an old-generation report recreated a cleared DTC'
	d.apply(m.control_gen(0))
	m.consume(0, d.rep)
	assert m.slots[0].status == status_cleared
	d.step(.failed, 0, true) // a NEW failure after the clear is recorded again
	m.consume(0, d.rep)
	assert m.slots[0].status & confirmed != 0 && m.slots[0].occurrence == 1
	assert !m.clear(0x300), 'unknown DTC'
	assert m.clear(0xFFFFFF)
	assert m.slots[0].status == status_cleared && m.slots[1].status == status_cleared
}

// 0x85 off: nothing recorded while off, and nothing that happened meanwhile replayed after on.
fn test_setting_off_records_nothing_and_replays_nothing() {
	mut m := memory([u32(1)])
	mut d := counter(1, 1)
	m.cycle_start()
	m.consume(0, d.rep)
	m.set_setting(false)
	d.step(.failed, 0, true)
	m.consume(0, d.rep)
	assert m.slots[0].status == status_cleared
	m.set_setting(true)
	m.consume(0, d.rep)
	assert m.slots[0].status == status_cleared, 'a suppressed failure was replayed'
	d.step(.passed, 0, true)
	d.step(.failed, 0, true)
	m.consume(0, d.rep)
	assert m.slots[0].status & test_failed != 0
}

// Outside an operation cycle nothing is recorded.
fn test_no_cycle_no_recording() {
	mut m := memory([u32(1)])
	mut d := counter(1, 1)
	d.step(.failed, 0, true)
	m.consume(0, d.rep)
	assert m.slots[0].status == status_cleared
}

fn server(mut m Memory) uds.Server {
	mut s := uds.Server{}
	s.init(256)
	s.faults = m.uds_ops()
	return s
}

fn call(mut s uds.Server, req []u8) []u8 {
	mut resp := [256]u8{}
	n := s.handle(&req[0], req.len, &resp[0])
	mut out := []u8{}
	for i in 0 .. n {
		out << resp[i]
	}
	return out
}

// 0x19 01 / 02 / 0A and 0x14 through the diagnostic server.
fn test_read_and_clear_over_uds() {
	mut m := memory([u32(0xC10000), u32(0x523000)])
	mut s := server(mut m)
	mut d := counter(1, 1)
	m.cycle_start()
	d.step(.failed, 0, true)
	m.consume(1, d.rep)
	assert call(mut s, [u8(0x19), 0x01, 0x08]) == [u8(0x59), 0x01, 0x7F, 0x01, 0x00, 0x01]
	assert call(mut s, [u8(0x19), 0x02, 0x08]) == [u8(0x59), 0x02, 0x7F, 0x52, 0x30, 0x00, 0x2F]
	assert call(mut s, [u8(0x19), 0x0A]) == [u8(0x59), 0x0A, 0x7F, 0xC1, 0x00, 0x00, 0x50, 0x52,
		0x30, 0x00, 0x2F]
	assert call(mut s, [u8(0x19), 0x04, 0x52, 0x30, 0x00, 0x01]) == [u8(0x7F), 0x19, 0x12] // R6
	assert call(mut s, [u8(0x19), 0x02]) == [u8(0x7F), 0x19, 0x13]
	assert call(mut s, [u8(0x19), 0x82, 0x08]) == [u8(0x7F), 0x19, 0x12] // no suppression on 0x19
	assert call(mut s, [u8(0x14), 0x12, 0x34, 0x56]) == [u8(0x7F), 0x14, 0x31]
	assert call(mut s, [u8(0x14), 0xFF, 0xFF]) == [u8(0x7F), 0x14, 0x13]
	assert call(mut s, [u8(0x14), 0xFF, 0xFF, 0xFF]) == [u8(0x54)]
	assert call(mut s, [u8(0x19), 0x01, 0x08]) == [u8(0x59), 0x01, 0x7F, 0x01, 0x00, 0x00]
}

// 0x85: extended session only; off stops recording; the session ending turns it back on (§7 R4).
fn test_dtc_setting_over_uds_and_restored_at_session_end() {
	mut m := memory([u32(1)])
	mut s := server(mut m)
	assert call(mut s, [u8(0x85), 0x02]) == [u8(0x7F), 0x85, 0x7F]
	call(mut s, [u8(0x10), 0x03])
	assert call(mut s, [u8(0x85), 0x02]) == [u8(0xC5), 0x02]
	assert m.setting_off
	assert call(mut s, [u8(0x85), 0x03]) == [u8(0x7F), 0x85, 0x12]
	call(mut s, [u8(0x10), 0x01])
	assert !m.setting_off, 'returning to default did not turn DTC setting back on'
	call(mut s, [u8(0x10), 0x03])
	assert call(mut s, [u8(0x85), 0x82]).len == 0 // suppressed positive response, still applied
	assert m.setting_off
	s.tick(0)
	s.tick(uds.default_s3_us + 1) // S3
	assert !m.setting_off, 'S3 did not turn DTC setting back on'
	call(mut s, [u8(0x10), 0x03])
	call(mut s, [u8(0x85), 0x02])
	s.reset_state()
	assert !m.setting_off, 'a reset did not turn DTC setting back on'
}

// A server with no fault memory does not serve these services at all.
fn test_without_a_fault_memory_the_services_are_unsupported() {
	mut s := uds.Server{}
	s.init(256)
	assert call(mut s, [u8(0x19), 0x0A]) == [u8(0x7F), 0x19, 0x11]
	assert call(mut s, [u8(0x14), 0xFF, 0xFF, 0xFF]) == [u8(0x7F), 0x14, 0x11]
}

// A gap (disabled / not tested) restarts a time-based run: the time held before it never counts.
fn test_time_debounce_restarts_after_a_gap() {
	mut d := Debounce{
		time_based: true
		fail_thr:   1000
		pass_thr:   1000
	}
	d.step(.failed, 0, true)
	d.step(.failed, 10_000_000, false) // enable condition false for 10 s
	d.step(.failed, 10_000_001, true)
	assert !d.rep.failed, 'qualified on time held before the enable condition went away'
	d.step(.failed, 10_001_001, true)
	assert d.rep.failed
}

// 0x85 off freezes the status through operation-cycle boundaries too.
fn test_setting_off_freezes_cycle_bits() {
	mut m := memory([u32(1)])
	m.slots[0].aging = 1
	mut d := counter(1, 1)
	m.cycle_start()
	d.step(.failed, 0, true)
	m.consume(0, d.rep)
	m.cycle_end()
	m.cycle_start()
	d.step(.passed, 0, true)
	m.consume(0, d.rep)
	before := m.slots[0].status
	m.set_setting(false)
	m.cycle_end()
	m.cycle_start()
	assert m.slots[0].status == before, 'a cycle boundary changed the status while DTC setting was off'
}

// A passing cycle before confirmation, and aging out after it, both start confirmation over.
fn test_confirmation_starts_over_after_a_pass_or_aging() {
	mut m := memory([u32(1)])
	m.slots[0].confirm = 2
	m.slots[0].aging = 1
	mut d := counter(1, 1)
	cycle := fn (mut m Memory, mut d Debounce, r TestResult) {
		m.cycle_start()
		d.step(r, 0, true)
		m.consume(0, d.rep)
		m.cycle_end()
	}
	cycle(mut m, mut d, .failed)
	cycle(mut m, mut d, .passed) // breaks the run
	cycle(mut m, mut d, .failed)
	assert m.slots[0].status & confirmed == 0, 'two NON-consecutive failed cycles confirmed'
	cycle(mut m, mut d, .failed)
	assert m.slots[0].status & confirmed != 0
	cycle(mut m, mut d, .passed) // ages out (aging = 1)
	assert m.slots[0].status & confirmed == 0
	cycle(mut m, mut d, .failed)
	assert m.slots[0].status & confirmed == 0, 'one failed cycle after aging re-confirmed'
}

// A second cycle_start closes the open cycle first.
fn test_a_restart_closes_the_open_cycle() {
	mut m := memory([u32(1)])
	mut d := counter(1, 1)
	m.cycle_start()
	d.step(.failed, 0, true)
	m.consume(0, d.rep)
	m.cycle_start()
	d.step(.passed, 0, true)
	m.consume(0, d.rep)
	m.cycle_start() // no end in between: the passing cycle still clears pending
	assert m.slots[0].status & pending == 0
}

// A huge counter threshold is clamped, never wrapped into an instant qualification.
fn test_huge_threshold_does_not_wrap() {
	mut d := counter(0x8000_0000, 1)
	d.step(.failed, 0, true)
	assert !d.rep.failed
}

// FaultOps with no availability mask counts as not wired.
fn test_unwired_availability_leaves_services_unsupported() {
	mut m := memory([u32(1)])
	mut s := server(mut m)
	s.faults.avail = 0
	assert call(mut s, [u8(0x19), 0x0A]) == [u8(0x7F), 0x19, 0x11]
}

// §7 R4 / codex #301: a cycle begun while 0x85 froze the status keeps its OWN tested state — the
// stale not-completed bit from the previous cycle never counts as a test in this one.
fn test_a_frozen_status_is_not_read_as_this_cycles_test() {
	mut m := memory([u32(1)])
	m.slots[0].aging = 1
	mut d := counter(1, 1)
	m.cycle_start()
	d.step(.failed, 0, true)
	m.consume(0, d.rep)
	m.cycle_end()
	m.cycle_start()
	d.step(.passed, 0, true)
	m.consume(0, d.rep) // tested, so TNCTOC is clear
	m.set_setting(false)
	m.cycle_end()
	m.cycle_start() // frozen: TNCTOC stays clear, but this cycle has tested nothing
	m.set_setting(true)
	m.cycle_end()
	assert m.slots[0].status & confirmed != 0, 'an untested cycle aged the DTC out'
	assert m.slots[0].status & pending != 0, 'an untested cycle cleared pending'
}

// codex #301: every clear is a FRESH generation — a report the producer made after applying clear 1
// but before clear 2 must not count after clear 2; and a stalled producer's stale report never
// comes round again, however many clears pass.
fn test_every_clear_invalidates_all_earlier_reports() {
	mut m := memory([u32(1)])
	mut d := counter(1, 1)
	m.cycle_start()
	assert m.clear(1)
	d.apply(m.control_gen(0)) // producer applies clear 1 ...
	d.step(.failed, 0, true) // ... and fails before the consumer reads it
	between := d.rep
	assert m.clear(1) // clear 2
	m.consume(0, between)
	assert m.slots[0].status == status_cleared, 'a report made before clear 2 counted after it'
	stale := between
	for _ in 0 .. 70_000 { // far past a u16 wrap, with the producer silent
		m.clear(0xFFFFFF)
	}
	m.consume(0, stale)
	assert m.slots[0].status == status_cleared, 'the generation came round to a stale report'
}

// codex #301: a result the producer publishes during suppression, read only after "on", is not
// applied — the first reading after "on" is a baseline.
fn test_a_result_published_during_suppression_is_not_applied_after_on() {
	mut m := memory([u32(1)])
	mut d := counter(1, 1)
	m.cycle_start()
	m.consume(0, d.rep)
	m.set_setting(false)
	m.consume(0, d.rep) // the last reading while off
	d.step(.failed, 0, true) // published while still off, not yet read
	m.set_setting(true)
	m.consume(0, d.rep)
	assert m.slots[0].status == status_cleared, 'a suppressed result was applied after on'
	d.step(.passed, 0, true)
	d.step(.failed, 0, true)
	m.consume(0, d.rep)
	assert m.slots[0].status & test_failed != 0
}

// codex #301: "on" inside a cycle that began while off resets that cycle's bits in the status.
fn test_on_resets_the_cycle_bits_of_a_cycle_begun_while_off() {
	mut m := memory([u32(1)])
	mut d := counter(1, 1)
	m.cycle_start()
	d.step(.failed, 0, true)
	m.consume(0, d.rep)
	assert m.slots[0].status & test_failed_this_cycle != 0
	m.set_setting(false)
	m.cycle_start() // a new cycle, status frozen
	m.set_setting(true)
	assert m.slots[0].status & test_failed_this_cycle == 0, 'the previous cycle still showed as failed this cycle'
	assert m.slots[0].status & not_completed_this_cycle != 0
}

fn test_report_cell_fits_the_ioc_payload() {
	assert sizeof(Reports) <= 64
	assert sizeof(Control) <= 64
}
