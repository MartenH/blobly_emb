module fault

import comm.uds

// the helpers fault_test.v has, here under their own names (each _test.v compiles alone)
fn rcounter(fail u32, pass u32) Debounce {
	return Debounce{
		fail_thr: fail
		pass_thr: pass
		jump:     true
	}
}

fn rcall(mut s uds.Server, req []u8) []u8 {
	mut resp := [256]u8{}
	n := s.handle(&req[0], req.len, &resp[0])
	mut out := []u8{}
	for i in 0 .. n {
		out << resp[i]
	}
	return out
}

// @verifies REQ-DIAG-013 REQ-DIAG-014 REQ-DIAG-015
// (snapshots captured from the server's DIDs at the occurrence that allocates an entry, served by
//  0x19 03 / 04; extended data records served by 0x19 06; displacement when the entries are full.)

// snap_memory: DTCs 0xC1000k, each with the snapshot `[0xF1A0 (4 B), 0xF190 (2 B)]`, `cap` entries.
fn snap_memory(n int, cap int) Memory {
	mut m := Memory{}
	for i in 0 .. n {
		m.slots[i].dtc = u32(0xC10000 + i)
		m.slots[i].confirm = 1
		m.slots[i].freeze[0] = 0xF1A0
		m.slots[i].freeze_len[0] = 4
		m.slots[i].freeze[1] = 0xF190
		m.slots[i].freeze_len[1] = 2
		m.slots[i].nfreeze = 2
		m.slots[i].priority = 128
	}
	m.n = n
	m.cap = cap
	m.init()
	return m
}

// snap_server: a server holding the two snapshot DIDs; F1A0 = speed, F190 = "AB".
fn snap_server(mut m Memory, speed u32) uds.Server {
	mut s := uds.Server{}
	s.init(256)
	s.faults = m.uds_ops()
	s.dids[0] = uds.Did{
		id: 0xF1A0
	}
	set_speed(mut s, speed)
	s.dids[1] = uds.Did{
		id:  0xF190
		len: 2
	}
	s.dids[1].data[0] = `A`
	s.dids[1].data[1] = `B`
	s.ndid = 2
	return s
}

fn set_speed(mut s uds.Server, speed u32) {
	s.dids[0].len = 4
	s.dids[0].data[0] = u8(speed >> 24)
	s.dids[0].data[1] = u8(speed >> 16)
	s.dids[0].data[2] = u8(speed >> 8)
	s.dids[0].data[3] = u8(speed)
}

// fail_once: one occurrence of slot i (an undebounced result through a fresh producer), then the
// owner's capture.
fn fail_once(mut m Memory, mut d Debounce, i int, srv &uds.Server) {
	d.apply(m.control_gen(i), m.control_held(i))
	d.step(.failed, 0, true)
	m.consume(i, d.rep)
	if m.capture_due() {
		m.capture(srv)
	}
}

fn pass_once(mut m Memory, mut d Debounce, i int) {
	d.apply(m.control_gen(i), m.control_held(i))
	d.step(.passed, 0, true)
	m.consume(i, d.rep)
}

// The snapshot is the server's DIDs at the first occurrence — read as 0x22 reads them — kept
// through later occurrences, and served by 0x19 03 and 0x19 04 (record 0x01 or all).
fn test_a_snapshot_is_taken_at_the_first_occurrence_and_kept() {
	mut m := snap_memory(2, 2)
	mut s := snap_server(mut m, 120)
	mut d := rcounter(1, 1)
	m.cycle_start()
	assert rcall(mut s, [u8(0x19), 0x03]) == [u8(0x59), 0x03]
	fail_once(mut m, mut d, 1, &s)
	set_speed(mut s, 7)
	pass_once(mut m, mut d, 1)
	fail_once(mut m, mut d, 1, &s) // a second occurrence: the first snapshot stays
	assert m.slots[1].occurrence == 2
	assert rcall(mut s, [u8(0x19), 0x03]) == [u8(0x59), 0x03, 0xC1, 0x00, 0x01, 0x01]
	want := [u8(0x59), 0x04, 0xC1, 0x00, 0x01, 0x2F, 0x01, 0x02, 0xF1, 0xA0, 0x00, 0x00, 0x00, 120,
		0xF1, 0x90, `A`, `B`]
	assert rcall(mut s, [u8(0x19), 0x04, 0xC1, 0x00, 0x01, 0x01]) == want
	assert rcall(mut s, [u8(0x19), 0x04, 0xC1, 0x00, 0x01, 0xFF]) == want
	// a DTC with nothing stored: its header; an undefined record or DTC: out of range
	assert rcall(mut s, [u8(0x19), 0x04, 0xC1, 0x00, 0x00, 0x01]) == [u8(0x59), 0x04, 0xC1, 0x00,
		0x00, 0x50]
	assert rcall(mut s, [u8(0x19), 0x04, 0xC1, 0x00, 0x01, 0x02]) == [u8(0x7F), 0x19, 0x31]
	assert rcall(mut s, [u8(0x19), 0x04, 0xC1, 0x00, 0x09, 0x01]) == [u8(0x7F), 0x19, 0x31]
	assert rcall(mut s, [u8(0x19), 0x04, 0xC1, 0x00, 0x01]) == [u8(0x7F), 0x19, 0x13]
	assert rcall(mut s, [u8(0x19), 0x03, 0x00]) == [u8(0x7F), 0x19, 0x13]
}

// A live DID nothing has published yet (length 0 in the server) is captured zero-filled at its
// declared size: a record always has its fixed shape, which is what the tester decodes by.
fn test_a_snapshot_has_its_fixed_shape() {
	mut m := snap_memory(1, 1)
	mut s := snap_server(mut m, 0)
	s.dids[0].len = 0
	mut d := rcounter(1, 1)
	m.cycle_start()
	fail_once(mut m, mut d, 0, &s)
	assert rcall(mut s, [u8(0x19), 0x04, 0xC1, 0x00, 0x00, 0x01]) == [u8(0x59), 0x04, 0xC1, 0x00,
		0x00, 0x2F, 0x01, 0x02, 0xF1, 0xA0, 0x00, 0x00, 0x00, 0x00, 0xF1, 0x90, `A`, `B`]
	assert m.snap_len(0) == 11
}

// Extended data: 0x01 the occurrence counter (2 B), 0x02 the aging counter, 0x03 the failed-cycle
// counter; 0xFF all of them; anything else (0xFE included) out of range.
fn test_extended_data_records() {
	mut m := snap_memory(1, 1)
	m.slots[0].confirm = 3
	mut s := snap_server(mut m, 1)
	mut d := rcounter(1, 1)
	for _ in 0 .. 2 {
		m.cycle_start()
		fail_once(mut m, mut d, 0, &s)
		pass_once(mut m, mut d, 0)
		fail_once(mut m, mut d, 0, &s)
		m.cycle_end()
	}
	// three occurrences (the second cycle's first failure continues the first's last), two cycles
	assert rcall(mut s, [u8(0x19), 0x06, 0xC1, 0x00, 0x00, 0x01]) == [u8(0x59), 0x06, 0xC1, 0x00,
		0x00, 0x27, 0x01, 0x00, 0x03]
	assert rcall(mut s, [u8(0x19), 0x06, 0xC1, 0x00, 0x00, 0x03]) == [u8(0x59), 0x06, 0xC1, 0x00,
		0x00, 0x27, 0x03, 0x02]
	assert rcall(mut s, [u8(0x19), 0x06, 0xC1, 0x00, 0x00, 0xFF]) == [u8(0x59), 0x06, 0xC1, 0x00,
		0x00, 0x27, 0x01, 0x00, 0x03, 0x02, 0x00, 0x03, 0x02]
	assert rcall(mut s, [u8(0x19), 0x06, 0xC1, 0x00, 0x00, 0x04]) == [u8(0x7F), 0x19, 0x31]
	assert rcall(mut s, [u8(0x19), 0x06, 0xC1, 0x00, 0x00, 0xFE]) == [u8(0x7F), 0x19, 0x31]
	assert rcall(mut s, [u8(0x19), 0x06, 0xC1, 0x00, 0x00, 0x00]) == [u8(0x7F), 0x19, 0x31]
	assert rcall(mut s, [u8(0x19), 0x06, 0xC2, 0x00, 0x00, 0xFF]) == [u8(0x7F), 0x19, 0x31]
}

// The persisted counters saturate at their serialized width: an increment at the maximum stays
// there (docs/diagnostics.md §7, R6).
fn test_counters_saturate_at_their_width() {
	mut m := snap_memory(1, 1)
	m.slots[0].confirm = 255
	mut s := snap_server(mut m, 1)
	mut d := rcounter(1, 1)
	m.slots[0].occurrence = 0xFFFE
	m.slots[0].failed_cycles = 254
	for _ in 0 .. 3 {
		m.cycle_start()
		fail_once(mut m, mut d, 0, &s)
		pass_once(mut m, mut d, 0)
		m.cycle_end()
	}
	assert m.slots[0].occurrence == 0xFFFF
	assert m.slots[0].failed_cycles == 255
	assert rcall(mut s, [u8(0x19), 0x06, 0xC1, 0x00, 0x00, 0x01])#[6..] == [u8(0x01), 0xFF, 0xFF]
}

// Without the snapshot seam the new subfunctions stay unsupported, as before R6b.
fn test_without_snapshots_the_new_subfunctions_are_unsupported() {
	mut m := snap_memory(1, 1)
	mut s := snap_server(mut m, 0)
	s.faults.snapshot = unsafe { nil }
	assert rcall(mut s, [u8(0x19), 0x03]) == [u8(0x7F), 0x19, 0x12]
	assert rcall(mut s, [u8(0x19), 0x06, 0x00, 0x00, 0x01, 0x01]) == [u8(0x7F), 0x19, 0x12]
}

// An entry lives while the DTC is pending or confirmed: a DTC that heals before confirming loses
// it at the cycle end, an aged-out one when it ages out, and a clear frees it.
fn test_an_entry_is_freed_by_healing_aging_and_clearing() {
	mut m := snap_memory(1, 1)
	m.slots[0].confirm = 2
	m.slots[0].aging = 2
	mut s := snap_server(mut m, 1)
	mut d := rcounter(1, 1)
	m.cycle_start()
	fail_once(mut m, mut d, 0, &s)
	m.cycle_end()
	assert m.slots[0].entry != 0, 'freed while still pending'
	m.cycle_start()
	pass_once(mut m, mut d, 0)
	m.cycle_end()
	assert m.slots[0].entry == 0, 'a DTC that healed before confirming kept its snapshot'
	for _ in 0 .. 2 {
		m.cycle_start()
		fail_once(mut m, mut d, 0, &s)
		m.cycle_end()
	}
	assert m.slots[0].status & confirmed != 0 && m.slots[0].entry != 0
	m.cycle_start()
	pass_once(mut m, mut d, 0)
	m.cycle_end()
	assert m.slots[0].entry != 0, 'pending cleared, confirmed kept: the snapshot stays'
	m.cycle_start()
	pass_once(mut m, mut d, 0)
	m.cycle_end()
	assert m.slots[0].status & confirmed == 0 && m.slots[0].entry == 0, 'aged out but kept its snapshot'
	m.cycle_start()
	fail_once(mut m, mut d, 0, &s)
	assert m.slots[0].entry != 0
	assert m.clear(0xFFFFFF) == 0
	assert m.slots[0].entry == 0 && !m.entries[0].used, 'a clear kept the snapshot'
}

// Displacement (docs/diagnostics.md §3.3): with every entry taken, a new snapshot displaces the
// least important entry — then a passive one before a failed one, then the oldest — never one
// more important than itself, never one whose DTC failed this operation cycle, never an active
// confirmed one. A DTC that gets no entry keeps its status and counters; only the snapshot is
// missing.
fn test_displacement_by_priority_activity_and_age() {
	mut m := snap_memory(5, 2)
	m.slots[0].priority = 50
	m.slots[1].priority = 50
	m.slots[2].priority = 50
	m.slots[3].priority = 10 // the most important
	m.slots[4].priority = 200 // the least
	mut s := snap_server(mut m, 1)
	mut d := []Debounce{len: 5, init: rcounter(1, 1)}
	m.cycle_start()
	fail_once(mut m, mut d[0], 0, &s)
	fail_once(mut m, mut d[1], 1, &s)
	// both failed THIS cycle: neither may be displaced, so 2 gets none — its status is still kept
	fail_once(mut m, mut d[2], 2, &s)
	assert m.slots[2].entry == 0 && m.slots[2].status & pending != 0 && m.slots[2].occurrence == 1
	assert m.displaced == 0
	m.cycle_end()
	m.cycle_start()
	// a new cycle: 0 passes (passive); 1 is still testFailed and confirmed (active confirmed)
	pass_once(mut m, mut d[0], 0)
	pass_once(mut m, mut d[2], 2)
	fail_once(mut m, mut d[2], 2, &s) // an occurrence: displaces the passive 0, never the active 1
	assert m.slots[0].entry == 0 && m.slots[1].entry != 0 && m.slots[2].entry != 0
	assert m.displaced == 1
	assert m.slots[0].status & confirmed != 0 && m.slots[0].occurrence == 1, 'displacement touched the status'
	m.cycle_end()
	m.cycle_start()
	pass_once(mut m, mut d[1], 1) // 1 is passive now; 2 is still testFailed and confirmed
	fail_once(mut m, mut d[4], 4, &s) // the least important may not displace the more important 1
	assert m.slots[4].entry == 0 && m.displaced == 1
	fail_once(mut m, mut d[3], 3, &s) // the most important displaces the passive 1, never the active 2
	assert m.slots[1].entry == 0 && m.slots[3].entry != 0 && m.slots[2].entry != 0
	assert m.displaced == 2
}

// Among equally important passive entries, the oldest goes first.
fn test_displacement_takes_the_oldest_among_equals() {
	mut m := snap_memory(3, 2)
	mut s := snap_server(mut m, 1)
	mut d := []Debounce{len: 3, init: rcounter(1, 1)}
	m.cycle_start()
	fail_once(mut m, mut d[1], 1, &s) // older
	m.cycle_end()
	m.cycle_start()
	fail_once(mut m, mut d[0], 0, &s) // newer
	m.cycle_end()
	m.cycle_start()
	pass_once(mut m, mut d[0], 0)
	pass_once(mut m, mut d[1], 1)
	fail_once(mut m, mut d[2], 2, &s)
	assert m.slots[1].entry == 0, 'the newer entry was displaced before the older'
	assert m.slots[0].entry != 0 && m.slots[2].entry != 0
}

// The two entries displacement never takes, each where nothing else excludes it: one whose DTC
// failed in THIS cycle but has passed since (not active), and an active confirmed one that has not
// been retested this cycle (no failure this cycle).
fn test_displacement_never_takes_this_cycles_evidence_nor_an_active_confirmed_dtc() {
	mut m := snap_memory(2, 1)
	mut s := snap_server(mut m, 1)
	mut d := []Debounce{len: 2, init: rcounter(1, 1)}
	m.cycle_start()
	fail_once(mut m, mut d[0], 0, &s)
	pass_once(mut m, mut d[0], 0) // failed this cycle, passive now
	fail_once(mut m, mut d[1], 1, &s)
	assert m.slots[0].entry != 0 && m.slots[1].entry == 0, 'displaced an entry that failed this cycle'
	m.clear(0xFFFFFF)
	fail_once(mut m, mut d[0], 0, &s)
	m.cycle_end()
	m.cycle_start() // 0 is testFailed and confirmed from the last cycle, not retested in this one
	pass_once(mut m, mut d[1], 1)
	fail_once(mut m, mut d[1], 1, &s)
	assert m.slots[0].entry != 0 && m.slots[1].entry == 0, 'displaced an active confirmed DTC'
}

// Among equally important entries a passive one goes before one still failed, even a newer one.
fn test_displacement_prefers_a_passive_entry() {
	mut m := snap_memory(3, 2)
	m.slots[0].confirm = 2 // pending only: testFailed without confirmed is not protected
	mut s := snap_server(mut m, 1)
	mut d := []Debounce{len: 3, init: rcounter(1, 1)}
	m.cycle_start()
	fail_once(mut m, mut d[0], 0, &s) // older, and stays testFailed
	m.cycle_end()
	m.cycle_start()
	fail_once(mut m, mut d[1], 1, &s) // newer
	m.cycle_end()
	m.cycle_start()
	pass_once(mut m, mut d[1], 1) // passive
	fail_once(mut m, mut d[2], 2, &s)
	assert m.slots[1].entry == 0 && m.slots[0].entry != 0, 'a failed entry went before a passive one'
}

// No snapshot for a DTC whose failure is no longer stored when the owner gets to it — a cycle end
// that healed it, or a clear, in the same pass: it would describe nothing the memory holds.
fn test_no_snapshot_for_a_failure_no_longer_stored() {
	mut m := snap_memory(1, 1)
	mut s := snap_server(mut m, 1)
	mut d := rcounter(1, 1)
	m.cycle_start()
	d.apply(m.control_gen(0), m.control_held(0))
	d.step(.failed, 0, true)
	m.consume(0, d.rep)
	assert m.capture_due()
	m.slots[0].status &= ~(pending | confirmed) // what a healing cycle end leaves
	m.capture(&s)
	assert m.slots[0].entry == 0 && !m.capture_due()
}

// The snapshot is the values AT STORAGE: taken in the owner pass that consumes the qualifying
// report — a DID that moved between the report and that pass shows its new value, one that moves
// after the pass does not reach the stored snapshot.
fn test_a_snapshot_holds_the_values_at_storage() {
	mut m := snap_memory(1, 1)
	mut s := snap_server(mut m, 10) // the qualifying dispatch sees speed 10
	mut d := rcounter(1, 1)
	m.cycle_start()
	d.apply(m.control_gen(0), m.control_held(0))
	d.step(.failed, 0, true) // the report is published ...
	set_speed(mut s, 20) // ... the producer dispatches again before the owner pass ...
	m.consume(0, d.rep) // ... and the owner pass that consumes it stores the snapshot
	m.capture(&s)
	set_speed(mut s, 30)
	r := rcall(mut s, [u8(0x19), 0x04, 0xC1, 0x00, 0x00, 0x01])
	assert r[10..14] == [u8(0), 0, 0, 20], 'the snapshot is not the value at storage: ${r.hex()}'
}
