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
		jump:     true // most tests below want "N in a row"; the accumulating default has its own
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
	assert m.clear(0x100) == 0
	assert m.slots[0].status == status_cleared && m.slots[0].occurrence == 0
	d.step(.failed, 0, true) // still the old generation
	m.consume(0, d.rep)
	assert m.slots[0].status == status_cleared, 'an old-generation report recreated a cleared DTC'
	d.apply(m.control_gen(0), m.control_held(0))
	m.consume(0, d.rep)
	assert m.slots[0].status == status_cleared
	d.step(.failed, 0, true) // a NEW failure after the clear is recorded again
	m.consume(0, d.rep)
	assert m.slots[0].status & confirmed != 0 && m.slots[0].occurrence == 1
	assert m.clear(0x300) == 0x31, 'unknown DTC'
	assert m.clear(0xFFFFFF) == 0
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
	d.apply(m.control_gen(0), m.control_held(0)) // the producer applies the generation "on" began
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
	assert m.clear(1) == 0
	d.apply(m.control_gen(0), m.control_held(0)) // producer applies clear 1 ...
	d.step(.failed, 0, true) // ... and fails before the consumer reads it
	between := d.rep
	assert m.clear(1) == 0 // clear 2
	m.consume(0, between)
	assert m.slots[0].status == status_cleared, 'a report made before clear 2 counted after it'
	stale := between
	mut refused := 0
	for _ in 0 .. 70_000 { // far past a u16 wrap, with the producer silent
		if m.clear(0xFFFFFF) == 0x22 {
			refused++
		}
	}
	assert refused > 0, 'clears kept succeeding with no fresh generation to give'
	m.consume(0, stale)
	assert m.slots[0].status == status_cleared, 'the generation came round to a stale report'
	// once the producer reports again, clears are accepted again
	d.apply(m.control_gen(0), m.control_held(0))
	m.consume(0, d.rep)
	assert m.clear(1) == 0
}

// codex #301: a clear right after 0x85 on — two fresh generations in a row — still records the
// first post-clear failure.
fn test_a_clear_after_on_records_the_first_failure() {
	mut m := memory([u32(1)])
	mut d := counter(1, 1)
	m.cycle_start()
	m.consume(0, d.rep)
	m.set_setting(false)
	m.set_setting(true)
	assert m.clear(1) == 0
	d.apply(m.control_gen(0), m.control_held(0))
	d.step(.failed, 0, true)
	m.consume(0, d.rep)
	assert m.slots[0].status & test_failed != 0, 'the first failure after a clear was swallowed'
}

// codex #301: a result the producer publishes during suppression, read only after "on", is not
// applied — it carries the generation "on" left behind.
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
	d.apply(m.control_gen(0), m.control_held(0))
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

// ISO 14229-1 ControlDTCSetting: "off" survives a switch between non-default sessions and ends on
// the transition to the default session.
fn test_dtc_setting_off_survives_non_default_transitions() {
	mut m := memory([u32(1)])
	mut s := server(mut m)
	call(mut s, [u8(0x10), 0x03])
	call(mut s, [u8(0x85), 0x02])
	call(mut s, [u8(0x10), 0x03]) // re-enter extended
	assert m.setting_off, 'a non-default transition turned DTC setting back on'
	call(mut s, [u8(0x10), 0x01])
	assert !m.setting_off
}

// AUTOSAR-shaped counter: by default it ACCUMULATES across reversals, so an intermittent fault that
// fails 2 of every 3 dispatches still qualifies — with `jump` ("N in a row") it never would.
fn test_accumulating_counter_catches_an_intermittent_fault() {
	mut acc := Debounce{
		fail_thr: 3
		pass_thr: 3
	}
	mut row := Debounce{
		fail_thr: 3
		pass_thr: 3
		jump:     true
	}
	for _ in 0 .. 10 {
		for r in [TestResult.failed, .failed, .passed] {
			acc.step(r, 0, true)
			row.step(r, 0, true)
		}
	}
	assert acc.rep.failed && acc.rep.fails == 1, 'the accumulating counter missed an intermittent fault'
	assert !row.rep.failed, 'jump = true should need 3 failures in a row'
}

// Asymmetric steps: inc 2 / dec 1 fails fast and heals slowly.
fn test_asymmetric_steps() {
	mut d := Debounce{
		fail_thr: 4
		pass_thr: 4
		inc:      2
		dec:      1
	}
	d.step(.failed, 0, true)
	assert !d.rep.failed
	d.step(.failed, 0, true)
	assert d.rep.failed, 'two failures at inc 2 reach 4'
	for _ in 0 .. 7 {
		d.step(.passed, 0, true)
	}
	assert d.rep.failed, 'healing from +4 to -4 at dec 1 takes 8 passes'
	d.step(.passed, 0, true)
	assert !d.rep.failed
}

// fail = 1 with jump (the generator's default for it, whatever `pass` is): a single failed result
// after a healed run qualifies at once — accumulating from -pass would need pass+1 of them.
fn test_undebounced_counter_needs_jump_for_one_pass_events() {
	mut acc := Debounce{
		fail_thr: 1
		pass_thr: 3
	}
	mut jmp := Debounce{
		fail_thr: 1
		pass_thr: 3
		jump:     true
	}
	for _ in 0 .. 3 {
		acc.step(.passed, 0, true)
		jmp.step(.passed, 0, true)
	}
	acc.step(.failed, 0, true)
	jmp.step(.failed, 0, true)
	assert !acc.rep.failed, 'accumulating from -3 reaches only -2'
	assert jmp.rep.failed, 'with jump a one-pass failure qualifies'
}

// #364: zone_a's shape (an accumulating counter, fail 3 / pass 3). A failure held through the off
// window leaves the producer's counter saturated at +fail_thr, so after "on" ONE failed result —
// the input's last value, still the one received while off — qualified at once and was recorded,
// where a debounce that saw nothing of the off window needs fail_thr of them.
fn test_a_debounce_saturated_while_off_is_not_carried_past_on() {
	mut m := memory([u32(0xC40100)])
	mut d := Debounce{
		fail_thr: 3
		pass_thr: 3
	}
	m.cycle_start()
	for _ in 0 .. 8 {
		owner_pass(mut m, mut d, .passed)
	}
	m.set_setting(false)
	for _ in 0 .. 12 { // 600 ms of implausible speed at 50 ms
		owner_pass(mut m, mut d, .failed)
	}
	assert m.slots[0].status & failed_since_clear == 0, 'recorded while off'
	m.set_setting(true)
	for _ in 0 .. 2 { // the stale value, until the gateway's next frame overwrites it
		owner_pass(mut m, mut d, .failed)
	}
	for _ in 0 .. 12 {
		owner_pass(mut m, mut d, .passed)
	}
	assert m.slots[0].status & (failed_since_clear | confirmed | pending) == 0, 'a failure debounced while off was recorded after on (status 0x${m.slots[0].status.hex()})'
	// a failure genuinely after "on" is still recorded, once it debounces up from the healed -3
	for _ in 0 .. 5 {
		owner_pass(mut m, mut d, .failed)
	}
	assert m.slots[0].status & failed_since_clear == 0, 'qualified before fail_thr'
	owner_pass(mut m, mut d, .failed)
	assert m.slots[0].status & (test_failed | failed_since_clear | confirmed) == test_failed | failed_since_clear | confirmed
}

// #364: a failure confirmed before "off" and still failing after "on" is the same failure — the
// restarted debounce re-qualifies it, and that is not a second occurrence. A fresh one after a heal is.
fn test_a_failure_held_across_on_is_one_occurrence() {
	mut m := memory([u32(1)])
	mut d := Debounce{
		fail_thr: 3
		pass_thr: 3
	}
	m.cycle_start()
	for _ in 0 .. 4 {
		owner_pass(mut m, mut d, .failed)
	}
	assert m.slots[0].occurrence == 1
	m.set_setting(false)
	for _ in 0 .. 4 {
		owner_pass(mut m, mut d, .failed)
	}
	m.set_setting(true)
	for _ in 0 .. 4 {
		owner_pass(mut m, mut d, .failed)
	}
	assert m.slots[0].status & test_failed != 0
	assert m.slots[0].occurrence == 1, 'a failure held across on counted twice'
	for _ in 0 .. 6 {
		owner_pass(mut m, mut d, .passed)
	}
	assert m.slots[0].status & test_failed == 0
	for _ in 0 .. 6 {
		owner_pass(mut m, mut d, .failed)
	}
	assert m.slots[0].occurrence == 2, 'a failure after a heal is a new occurrence'
}

// "On" cannot be refused, so for a producer silent past the generation budget it renews nothing:
// the generation never wraps round to a stale report, and a clear stays refused until it reports.
fn test_on_never_wraps_a_silent_producers_generation() {
	mut m := memory([u32(1)])
	mut d := counter(1, 1)
	m.cycle_start()
	d.step(.failed, 0, true)
	stale := d.rep // generation 0, never read
	for _ in 0 .. 65_536 { // exactly one u16 wrap: an unbounded renewal lands back on 0
		m.set_setting(false)
		m.set_setting(true)
	}
	assert u16(m.control_gen(0) - stale.gen) < 0x8000, 'on wrapped the generation'
	m.consume(0, stale)
	assert m.slots[0].status == status_cleared, 'the generation came round to a stale report'
	assert m.clear(1) == 0x22
	d.apply(m.control_gen(0), m.control_held(0))
	m.consume(0, d.rep)
	assert m.clear(1) == 0, 'a clear stayed refused after the producer reported'
}

// owner_pass is one dispatch as the generated code runs it: apply the control generation, step, consume.
fn owner_pass(mut m Memory, mut d Debounce, r TestResult) {
	d.apply(m.control_gen(0), m.control_held(0))
	d.step(r, 0, true)
	m.consume(0, d.rep)
}

// The producer/consumer protocol as a model, checked over random interleavings (#364). Two faults,
// each debounced on its own producer thread: a dispatch applies the control cell, steps, and
// publishes its report cell; an owner pass consumes both cells and publishes the control cells, at
// random times, so the consumer is slower or faster than the producer at will. Between them: 0x85
// off and on (a session end is the same "on"), clears by group and by DTC, and now and then a storm
// of generations with the producers silent, which exhausts the generation budget.
//
// The abstract memory says what REQ-DIAG-009 allows. A producer EPOCH is its debounce since it last
// restarted. It is ELIGIBLE while setting is on, if the restart was requested after the last off/on
// and the last clear and happened after that request (a generation is only an identity here: the
// model notes when the memory issued each one). A reference debounce — written here from the
// documented rule, not the module's — restarted in the state the abstract memory shows, runs on the
// same results. An owner pass counts exactly what the reports it
// reads from an eligible epoch add, and nothing else — a report made while off, before "on", before
// a clear — ever counts, and outside an operation cycle it counts nothing either. A clear may be
// refused only while a storm has left a fault's producer without a report since. After every action: the occurrence count, testFailed and
// testFailedSinceLastClear are the abstract memory's, and an owner pass while off changes no status.
struct EpochMeta {
mut:
	epoch  int
	fails  u16 // the reference debounce's occurrences, this epoch
	tests  u16
	failed bool
}

// RefDeb: the debounce as docs/diagnostics.md §3.3 states it — a counter from -pass to +fail moved by
// inc / dec (reset on a reversal with jump), or a run of equal results held fail / pass µs; a gap
// holds the counter and restarts a run; failed qualifies once, every result at a threshold is a test.
struct RefDeb {
mut:
	tb     bool
	fthr   i64
	pthr   i64
	inc    i64
	dec    i64
	jump   bool
	c      i64
	run    TestResult
	since  u64
	failed bool
	fails  u16
	tests  u16
}

fn ref_of(d Debounce, failed bool) RefDeb {
	one := fn (x u32) i64 {
		return if x == 0 { i64(1) } else { i64(x) }
	}
	return RefDeb{
		tb:     d.time_based
		fthr:   if d.time_based { i64(d.fail_thr) } else { one(d.fail_thr) }
		pthr:   if d.time_based { i64(d.pass_thr) } else { one(d.pass_thr) }
		inc:    one(d.inc)
		dec:    one(d.dec)
		jump:   d.jump
		failed: failed
	}
}

fn (mut r RefDeb) step(x TestResult, now u64, en bool) {
	if !en || x == .not_tested {
		r.run = .not_tested
		return
	}
	mut f := false
	mut p := false
	if r.tb {
		if x != r.run {
			r.run = x
			r.since = now
		}
		f = x == .failed && now - r.since >= u64(r.fthr)
		p = x == .passed && now - r.since >= u64(r.pthr)
	} else {
		if x == .failed {
			r.c = if r.jump && r.c < 0 { r.inc } else { r.c + r.inc }
			r.c = if r.c > r.fthr { r.fthr } else { r.c }
		} else {
			r.c = if r.jump && r.c > 0 { -r.dec } else { r.c - r.dec }
			r.c = if r.c < -r.pthr { -r.pthr } else { r.c }
		}
		f = r.c >= r.fthr
		p = r.c <= -r.pthr
	}
	if f {
		if !r.failed {
			r.failed = true
			r.fails++
		}
		r.tests++
	} else if p {
		r.failed = false
		r.tests++
	}
}

struct FaultAbs {
mut:
	t_apply   int // when the producer last restarted
	g_apply   u16 // the generation it restarted on
	t_clear   int = -1
	issued    map[u16]int // when the memory issued each generation (its latest issue)
	last_gen  u16
	epoch     int
	reference RefDeb
	spent     bool // a storm spent its generations and no report from its producer has been read since
	pub_fresh bool // the control cell has been published since that storm
	rep_fresh bool // the producer has reported on a control published since that storm
	cell      EpochMeta // what the published report cell carries
	base      EpochMeta // what the abstract memory last counted
	occ       u16
	tf        bool
	tfslc     bool
}

// note_issue: the memory's control generation for fault k changed — a restart requested at `clock`
fn note_issue(m &Memory, mut abs []FaultAbs, clock int) {
	for k in 0 .. abs.len {
		g := m.control_gen(k)
		if g != abs[k].last_gen {
			abs[k].last_gen = g
			abs[k].issued[g] = clock
		}
	}
}

fn test_the_fault_protocol_model_holds_over_random_interleavings() {
	mut rng := u32(0x9E3779B9)
	mut storms := 0
	mut held_restarts := 0
	mut waits := 0
	mut clock := 0
	for run in 0 .. 400 {
		rng ^= rng << 13
		rng ^= rng >> 17
		rng ^= rng << 5
		local := rng & 1 == 1 // the producer reads the memory directly (a signal-status fault)
		proto := Debounce{
			time_based: rng & 2 != 0
			fail_thr:   if rng & 2 != 0 { u32(150) } else { 1 + (rng >> 2) % 4 }
			pass_thr:   if rng & 2 != 0 { u32(300) } else { 1 + (rng >> 4) % 4 }
			inc:        1 + (rng >> 6) % 2
			jump:       rng & 0x100 != 0
		}
		mut m := memory([u32(0xC40100), u32(0xC40200)])
		m.cycle_start()
		mut d := [proto, proto]
		mut cells := [Report{}, Report{}]
		mut ctl := Control{}
		mut abs := []FaultAbs{len: 2, init: FaultAbs{
			reference: ref_of(proto, false)
		}}
		for k in 0 .. 2 {
			abs[k].issued[0] = clock // power-on: generation 0, the producer started on it
			abs[k].t_apply = clock
		}
		mut phase := [TestResult.passed, .passed]
		mut t_toggle := -1 // the last off->on or on->off
		mut now := u64(0)
		for step in 0 .. 1000 {
			clock++
			rng ^= rng << 13
			rng ^= rng >> 17
			rng ^= rng << 5
			op := rng % 100
			ctx := 'run ${run} step ${step} op ${op} local ${local}'
			now += 10
			if op < 45 {
				// a producer dispatch
				k := int((rng >> 8) & 1)
				if (rng >> 9) % 8 == 0 {
					phase[k] = [TestResult.failed, .passed, .not_tested][(rng >> 12) % 3]
				}
				r := if (rng >> 14) % 10 == 0 { TestResult.passed } else { phase[k] }
				en := (rng >> 18) % 20 != 0
				gen := if local { m.control_gen(k) } else { ctl.gen[k] }
				held := if local { m.control_held(k) } else { ctl.held[k] }
				if gen != d[k].rep.gen {
					abs[k].t_apply = clock
					abs[k].g_apply = gen
					abs[k].epoch++
					abs[k].reference = ref_of(proto, abs[k].tf) // restarted in the state the memory shows
					if abs[k].tf {
						held_restarts++
					}
				}
				d[k].apply(gen, held)
				d[k].step(r, now, en)
				cells[k] = d[k].rep
				if abs[k].spent && (local || abs[k].pub_fresh) {
					abs[k].rep_fresh = true
				}
				abs[k].reference.step(r, now, en)
				abs[k].cell = EpochMeta{
					epoch:  abs[k].epoch
					fails:  abs[k].reference.fails
					tests:  abs[k].reference.tests
					failed: abs[k].reference.failed
				}
			} else if op < 80 {
				// an owner pass
				for k in 0 .. 2 {
					before := m.slots[k].status
					if m.slots[k].wait_gen {
						waits++
					}
					m.consume(k, cells[k])
					note_issue(m, mut abs, clock)
					ctl.gen[k] = m.control_gen(k)
					ctl.held[k] = m.control_held(k)
					if abs[k].rep_fresh {
						abs[k].spent = false
						abs[k].rep_fresh = false
					}
					abs[k].pub_fresh = abs[k].spent
					if m.setting_off {
						assert m.slots[k].status == before, '${ctx}: a status bit changed while off'
						continue
					}
					mut a := unsafe { &abs[k] }
					ti := a.issued[a.g_apply] or { -1 }
					if ti < t_toggle || ti < a.t_clear || a.t_apply < ti || a.cell.epoch != a.epoch {
						continue // not eligible: nothing it carries may count
					}
					if !m.cycle_active {
						a.base = a.cell // outside a cycle: the baselines follow, nothing counts
						continue
					}
					base := if a.base.epoch == a.cell.epoch { a.base } else { EpochMeta{} }
					dfails := a.cell.fails - base.fails
					dtests := a.cell.tests - base.tests
					if dtests > 0 {
						a.tf = a.cell.failed
					}
					if dfails > 0 || (a.cell.failed && dtests > 0) {
						a.tfslc = true
					}
					a.occ += dfails
					a.base = a.cell
				}
			} else if op < 88 {
				if !m.setting_off {
					t_toggle = clock
				}
				m.set_setting(false)
			} else if op < 96 {
				if m.setting_off {
					t_toggle = clock
				}
				m.set_setting(true) // 0x85 on, or the session ending
				note_issue(m, mut abs, clock)
			} else if op == 98 {
				// an operation cycle boundary: while off it changes no status
				before := [m.slots[0].status, m.slots[1].status]
				if (rng >> 8) & 1 == 0 {
					m.cycle_start()
				} else {
					m.cycle_end()
				}
				if m.setting_off {
					assert [m.slots[0].status, m.slots[1].status] == before, '${ctx}: a cycle boundary changed a status while off'
				}
			} else if op < 98 || (rng >> 8) % 4 != 0 {
				group := if (rng >> 10) & 1 == 0 { u32(0xFFFFFF) } else { m.slots[(rng >> 11) & 1].dtc }
				nrc := m.clear(group)
				if nrc != 0 {
					assert nrc == 0x22 && ((group == 0xFFFFFF && (abs[0].spent || abs[1].spent))
						|| (group == m.slots[0].dtc && abs[0].spent)
						|| (group == m.slots[1].dtc && abs[1].spent)), '${ctx}: clear refused (0x${nrc.hex()}) with every producer reporting'
				} else {
					for k in 0 .. 2 {
						if group == 0xFFFFFF || m.slots[k].dtc == group {
							abs[k].t_clear = clock
							abs[k].occ = 0
							abs[k].tf = false
							abs[k].tfslc = false
						}
					}
				}
				note_issue(m, mut abs, clock)
			} else {
				// a storm: generations spent with both producers silent, past the budget
				storms++
				for k in 0 .. 2 {
					abs[k].spent = true
					abs[k].pub_fresh = false
					abs[k].rep_fresh = false
				}
				for _ in 0 .. 0x8001 {
					m.set_setting(false)
					m.set_setting(true)
				}
				note_issue(m, mut abs, clock) // every generation the storm issued, issued during it
				clock++
				t_toggle = clock // its last "on", which found none free
				if (rng >> 10) & 1 == 0 {
					clock++
					m.set_setting(false)
					t_toggle = clock
				}
			}
			for k in 0 .. 2 {
				s := m.slots[k]
				a := abs[k]
				assert s.occurrence == a.occ, '${ctx}: fault ${k} occurrences ${s.occurrence}, the model ${a.occ}'
				assert (s.status & test_failed != 0) == a.tf, '${ctx}: fault ${k} testFailed, the model ${a.tf} (status 0x${s.status.hex()})'
				assert (s.status & failed_since_clear != 0) == a.tfslc, '${ctx}: fault ${k} testFailedSinceLastClear, the model ${a.tfslc} (status 0x${s.status.hex()})'
			}
		}
	}
	println('fault model: ${storms} storms, ${waits} waits, ${held_restarts} held restarts')
	assert storms > 3, 'the model never exhausted the generations'
	assert waits > 0, 'no slot ever waited for a fresh generation'
	assert held_restarts > 100, 'the model rarely restarted a failed debounce'
}
