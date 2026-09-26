module trace

import driver.can

// The host multi-core command path (P3a, emb#191): one owner partition serving its OWN ring plus
// a satellite core's ring. These pin the properties the generated runner depends on — a dump that
// returns a moving window, or an arm that reaches only one core, would both produce a trace that
// looks fine and lies.

fn cmd_frame(op u8, mask u16) can.Frame {
	b := encode_cmd(Cmd{
		opcode:    op
		core_mask: mask
	})
	mut f := can.Frame{
		id:  0x7e2
		len: 8
	}
	for i in 0 .. 8 {
		f.data[i] = b[i]
	}
	return f
}

// NOTE: every test declares its ring backings as its OWN locals. A helper that built them and
// returned the TraceBuffer would hand back a buffer pointing at an array that died with the
// helper — the first version of this file did exactly that and read 2888 out of a freed frame.

// A dump must NOT touch a capturing satellite. It is refused, exactly as handle_cmd refuses one
// against the owner's own capturing ring. An earlier version froze it here, so a dump the owner
// then rejected (not_ready, or busy) still destroyed core 1's flight recorder and pushed out an
// unsolicited block — a failed command must leave both rings as it found them.
fn test_dump_does_not_freeze_or_read_a_capturing_satellite() {
	mut own := [16]Record{}
	mut satb := [16]Record{}
	mut remote := [64]Record{}
	mut m := new_module(0x7e3, 0x7e5, 0, true, new_buffer(&own[0], 16, .ring, 50))
	mut sat := new_buffer(&satb[0], 16, .ring, 50)
	sat.start()
	for i in 0 .. 3 {
		m.push(new_fb(u16(100 + i), 0, u32(i), 1))
		sat.push(new_fb(u16(200 + i), 0, u32(i), 1))
	}
	m.on_cmd(cmd_frame(op_stop, 0xffff)) // owner's own ring: stopped, so ITS dump would be legal
	assert sat.state() == .capturing, 'precondition: the satellite is still recording'

	imported := m.on_cmd_multicore(cmd_frame(op_dump, 0x0003), mut sat, 1, &remote[0], 64, zero_clock)

	assert !imported, 'a capturing satellite window was read'
	assert sat.state() == .capturing, 'the dump froze the satellite instead of refusing'
	assert sat.used() == 3, 'the satellite window was disturbed'
}

// The normal sequence — stop, then dump — does import it.
fn test_a_stopped_satellite_is_imported_on_dump() {
	mut own := [16]Record{}
	mut satb := [16]Record{}
	mut remote := [64]Record{}
	mut m := new_module(0x7e3, 0x7e5, 0, true, new_buffer(&own[0], 16, .ring, 50))
	mut sat := new_buffer(&satb[0], 16, .ring, 50)
	sat.start()
	for i in 0 .. 3 {
		m.push(new_fb(u16(100 + i), 0, u32(i), 1))
		sat.push(new_fb(u16(200 + i), 0, u32(i), 1))
	}
	m.on_cmd_multicore(cmd_frame(op_stop, 0x0003), mut sat, 1, &remote[0], 64, zero_clock)
	assert sat.state() != .capturing, 'stop did not reach the satellite'

	assert m.on_cmd_multicore(cmd_frame(op_dump, 0x0003), mut sat, 1, &remote[0], 64, zero_clock)
}

// A ring that has wrapped past its oldest epoch keeps that epoch's base in prefix_base, and every
// packed block anchors from it. Importing only the records left the satellite's window anchored at
// 0, shifting its whole lane by however long that core had been running.
fn test_the_import_carries_the_epoch_prefix() {
	mut own := [16]Record{}
	mut satb := [4]Record{}
	mut remote := [64]Record{}
	mut m := new_module(0x7e3, 0x7e5, 0, true, new_buffer(&own[0], 16, .ring, 50))
	mut sat := new_buffer(&satb[0], 4, .ring, 50)
	sat.start()
	sat.push(new_epoch(1_000_000)) // ages out as the ring wraps, leaving its base as the prefix
	for i in 0 .. 6 {
		sat.push(new_fb(u16(200 + i), 0, u32(i), 1))
	}
	sat.stop()
	assert sat.has_prefix, 'precondition: the satellite ring wrapped past its epoch'

	m.on_cmd(cmd_frame(op_stop, 0xffff))
	assert m.on_cmd_multicore(cmd_frame(op_dump, 0x0003), mut sat, 1, &remote[0], 64, zero_clock)

	assert m.remote.has_prefix, 'the imported window lost the epoch prefix'
	assert m.remote.prefix_base == sat.prefix_base
}

// arm/reset must reach BOTH cores, or the two windows cover different spans of time.
fn test_arm_reaches_the_satellite_too() {
	mut own := [16]Record{}
	mut satb := [16]Record{}
	mut remote := [64]Record{}
	mut m := new_module(0x7e3, 0x7e5, 0, true, new_buffer(&own[0], 16, .ring, 50))
	mut sat := new_buffer(&satb[0], 16, .ring, 50)
	sat.start()
	for i in 0 .. 4 {
		sat.push(new_fb(u16(200 + i), 0, u32(i), 1))
	}
	sat.stop()
	assert sat.used() == 4

	m.on_cmd_multicore(cmd_frame(op_arm, 0xffff), mut sat, 1, &remote[0], 64, zero_clock)

	assert sat.state() == .capturing, 'arm did not restart the satellite'
	assert sat.used() == 0, 'arm did not clear the satellite window'
}

// The core mask is a filter, not a suggestion: a command aimed at core 0 alone must not disturb
// core 1's ring. (0x0001 selects core 0 only.)
fn test_a_command_that_excludes_the_satellite_leaves_it_alone() {
	mut own := [16]Record{}
	mut satb := [16]Record{}
	mut remote := [64]Record{}
	mut m := new_module(0x7e3, 0x7e5, 0, true, new_buffer(&own[0], 16, .ring, 50))
	mut sat := new_buffer(&satb[0], 16, .ring, 50)
	sat.start()
	for i in 0 .. 2 {
		sat.push(new_fb(u16(200 + i), 0, u32(i), 1))
	}
	before := sat.used()

	m.on_cmd_multicore(cmd_frame(op_stop, 0x0001), mut sat, 1, &remote[0], 64, zero_clock)

	assert sat.state() == .capturing, 'a core-0 command stopped core 1'
	assert sat.used() == before
}

// An empty satellite window must produce NO block rather than a block claiming zero records:
// the host distinguishes "core 1 captured nothing" from "core 1 was never asked".
fn test_an_empty_satellite_imports_nothing() {
	mut own := [16]Record{}
	mut satb := [16]Record{}
	mut remote := [64]Record{}
	mut m := new_module(0x7e3, 0x7e5, 0, true, new_buffer(&own[0], 16, .ring, 50))
	mut sat := new_buffer(&satb[0], 16, .ring, 50)
	sat.start()
	sat.stop() // stopped with nothing captured
	m.on_cmd(cmd_frame(op_stop, 0xffff))

	imported := m.on_cmd_multicore(cmd_frame(op_dump, 0x0003), mut sat, 1, &remote[0], 64, zero_clock)

	assert !imported, 'an empty satellite window was imported as a block'
}

// The imported block carries the SATELLITE's records under the SATELLITE's core id — the owner's
// own window must not be duplicated or relabelled.
fn test_the_imported_block_is_the_satellites_records() {
	mut own := [16]Record{}
	mut satb := [16]Record{}
	mut remote := [64]Record{}
	mut m := new_module(0x7e3, 0x7e5, 0, true, new_buffer(&own[0], 16, .ring, 50))
	mut sat := new_buffer(&satb[0], 16, .ring, 50)
	sat.start()
	for i in 0 .. 3 {
		m.push(new_fb(u16(100 + i), 0, u32(i), 1))
		sat.push(new_fb(u16(200 + i), 0, u32(i), 1))
	}
	// stop reaches BOTH rings, then dump reads them — the normal host sequence
	m.on_cmd_multicore(cmd_frame(op_stop, 0x0003), mut sat, 1, &remote[0], 64, zero_clock)
	assert m.on_cmd_multicore(cmd_frame(op_dump, 0x0003), mut sat, 1, &remote[0], 64, zero_clock)

	// the remote window holds core 1's ids (200..), not the owner's (100..)
	assert m.remote.used() == 3, 'expected 3 imported records, got ${m.remote.used()}'
	assert m.remote_core == 1
	for i in 0 .. 3 {
		assert m.remote.record_at(u32(i)).id() == u16(200 + i)
	}
}

// A command addressed to the SATELLITE ONLY (mask 0x0002 selects core 1) does not select the
// owner, so handle_cmd reports it unaddressed and answers nothing. The host would see silence and
// be unable to tell a busy target from a wrong id — so the owner answers for the satellite.
fn test_a_satellite_only_command_still_gets_a_response() {
	mut own := [16]Record{}
	mut satb := [16]Record{}
	mut remote := [64]Record{}
	mut m := new_module(0x7e3, 0x7e5, 0, true, new_buffer(&own[0], 16, .ring, 50))
	mut sat := new_buffer(&satb[0], 16, .ring, 50)
	sat.start()
	sat.push(new_fb(200, 0, 0, 1))

	m.on_cmd_multicore(cmd_frame(op_status, 0x0002), mut sat, 1, &remote[0], 64, zero_clock)

	assert m.rsp_pending(), 'a core-1-only command was answered with silence'
	r := decode_rsp(m.rsp)
	assert r.core == 1, 'the response claims core ${r.core}, not the satellite'
	assert r.opcode_echo == op_status
}

// When the mask selects BOTH cores the owner's own response stands — queue_rsp must refuse rather
// than overwrite it, or the host loses the answer for core 0.
fn test_a_both_core_command_keeps_the_owners_response() {
	mut own := [16]Record{}
	mut satb := [16]Record{}
	mut remote := [64]Record{}
	mut m := new_module(0x7e3, 0x7e5, 0, true, new_buffer(&own[0], 16, .ring, 50))
	mut sat := new_buffer(&satb[0], 16, .ring, 50)
	sat.start()

	m.on_cmd_multicore(cmd_frame(op_status, 0x0003), mut sat, 1, &remote[0], 64, zero_clock)

	assert m.rsp_pending()
	assert decode_rsp(m.rsp).core == 0, 'the satellite answer overwrote the owner\'s'
}

// A dump arriving in the IDLE GAP between continuation transfers must be refused. on_cmd's own
// busy check only covers the ISO-TP link, not a queued local_due/remote_due block, so such a dump
// used to be accepted: it reset the local cursor and re-sent the owner's blocks ahead of the
// satellite block still queued behind them, corrupting the multi-core stream.
fn test_a_dump_during_a_queued_stream_is_refused() {
	mut own := [16]Record{}
	mut satb := [16]Record{}
	mut remote := [64]Record{}
	mut m := new_module(0x7e3, 0x7e5, 0, true, new_buffer(&own[0], 16, .ring, 50))
	mut sat := new_buffer(&satb[0], 16, .ring, 50)
	sat.start()
	for i in 0 .. 3 {
		m.push(new_fb(u16(100 + i), 0, u32(i), 1))
		sat.push(new_fb(u16(200 + i), 0, u32(i), 1))
	}
	m.on_cmd_multicore(cmd_frame(op_stop, 0x0003), mut sat, 1, &remote[0], 64, zero_clock)
	assert m.on_cmd_multicore(cmd_frame(op_dump, 0x0003), mut sat, 1, &remote[0], 64, zero_clock)
	assert m.is_dumping(), 'precondition: a dump is queued'
	// drain the first dump's response the way the bus loop does each pass, so the busy answer
	// below is not refused by queue_rsp's don't-overwrite rule
	mut f := can.Frame{}
	m.produce(1000, mut f)
	assert !m.rsp_pending()

	// second dump, while blocks are still queued
	imported := m.on_cmd_multicore(cmd_frame(op_dump, 0x0003), mut sat, 1, &remote[0], 64, zero_clock)

	assert !imported, 'the satellite window was re-imported mid-stream'
	assert m.rsp_pending(), 'the refused dump was not answered'
	assert decode_rsp(m.rsp).result == result_busy, 'expected BUSY, got ${decode_rsp(m.rsp).result}'
}

// An arm/start/reset starts a new freeze GENERATION, whichever cores the mask names, BEFORE any
// ring restarts — the retirement of whatever the last window raised (#273; the flag cell of #271
// r2 cleared instead). A dump consumes nothing, and a mask naming neither core restarts nothing.
fn test_an_arm_starts_a_new_generation_for_any_mask() {
	mut ring := [64]Record{}
	mut m := TraceModule{}
	m.init(0x7e3, 0x7e5, 0, true, new_buffer(&ring[0], 64, .ring, 50))
	mut cell := FreezeSync{}
	cell.word = 1 // a trigger froze the system in generation 0
	m.set_freeze(&cell)
	mut sat_ring := [64]Record{}
	mut sat := new_buffer(&sat_ring[0], 64, .ring, 50)
	mut remote := [65]Record{}
	m.on_cmd_multicore(cmd_frame(op_arm, 0x0002), mut sat, 1, &remote[0], 65, zero_clock) // satellite ALONE
	assert cell.word == 1 << 1 // generation 1, unraised
	assert cell.rearm == 1 // ...and the satellite's restart posted with it
	cell.word = (1 << 1) | 1
	cell.ack = 1 // (the satellite performed it)
	m.on_cmd_multicore(cmd_frame(op_dump, 0x0003), mut sat, 1, &remote[0], 65, zero_clock)
	assert cell.word == (1 << 1) | 1 // a dump consumes nothing
	m.on_cmd_multicore(cmd_frame(op_arm, 0x0004), mut sat, 1, &remote[0], 65, zero_clock)
	assert cell.word == (1 << 1) | 1 // a mask naming NEITHER core restarts nothing
	m.on_cmd_multicore(cmd_frame(op_reset, 0x0001), mut sat, 1, &remote[0], 65, zero_clock) // owner ALONE
	assert cell.word == 2 << 1
	assert cell.rearm == 1, 'an owner-only re-arm posted a satellite restart'
}

// Until the satellite performs a posted re-arm its ring still holds the window the host asked to
// discard: a stop or dump addressed to it is refused BUSY and touches nothing — a stop would be
// undone by the restart, a dump would stream the discarded window.
fn test_a_satellite_with_a_pending_rearm_refuses_stop_and_dump() {
	mut own := [16]Record{}
	mut satb := [16]Record{}
	mut remote := [64]Record{}
	mut m := new_module(0x7e3, 0x7e5, 0, true, new_buffer(&own[0], 16, .ring, 50))
	mut cell := FreezeSync{}
	m.set_freeze(&cell)
	mut sat := new_buffer(&satb[0], 16, .ring, 50)
	sat.start()
	for i in 0 .. 4 {
		sat.push(new_fb(u16(200 + i), 0, u32(i), 1))
	}
	sat.stop() // a frozen window, about to be discarded
	m.on_cmd_multicore(cmd_frame(op_arm, 0x0003), mut sat, 1, &remote[0], 64, zero_clock)
	assert sat.used() == 4, 'the owner restarted the satellite ring cross-thread'
	mut f := can.Frame{}
	for m.produce(0, mut f) {} // drain the arm's response
	for op in [op_stop, op_dump] {
		imported := m.on_cmd_multicore(cmd_frame(op, 0x0002), mut sat, 1, &remote[0], 64, zero_clock)
		assert !imported
		assert m.produce(0, mut f)
		assert f.data[1] == result_busy, 'op ${op} against a pending re-arm answered ${f.data[1]}'
		assert f.data[7] == 1
		assert sat.used() == 4 && sat.state() == .frozen // left exactly as found
	}
	// the satellite's next dispatch performs the restart; then the stop goes through
	mut sc := Capture{
		buf:       &sat
		freeze:    &cell
		satellite: true
	}
	fb_hook(voidptr(&sc), 0, 0, 1)
	assert sat.state() == .capturing && sat.used() == 1
	m.on_cmd_multicore(cmd_frame(op_stop, 0x0002), mut sat, 1, &remote[0], 64, zero_clock)
	assert sat.state() == .frozen
}

// A satellite-only arm answers with the window the satellite is ABOUT to open — capturing, empty —
// not the frozen one it is discarding, even though the restart is still only posted.
fn test_a_satellite_only_arm_answers_for_the_window_it_opens() {
	mut own := [16]Record{}
	mut satb := [16]Record{}
	mut remote := [64]Record{}
	mut m := new_module(0x7e3, 0x7e5, 0, true, new_buffer(&own[0], 16, .ring, 50))
	mut cell := FreezeSync{}
	m.set_freeze(&cell)
	mut sat := new_buffer(&satb[0], 16, .ring, 50)
	sat.start()
	sat.push(new_fb(200, 0, 0, 1))
	sat.stop()
	m.on_cmd_multicore(cmd_frame(op_arm, 0x0002), mut sat, 1, &remote[0], 64, zero_clock)
	mut f := can.Frame{}
	assert m.produce(0, mut f)
	r := decode_rsp([f.data[0], f.data[1], f.data[2], f.data[3], f.data[4], f.data[5], f.data[6],
		f.data[7]]!)
	assert r.result == result_ok
	assert r.state == state_code(.capturing)
	assert r.records_used == 0
	assert r.core == 1
	assert sat.state() == .frozen // the shared ring itself is untouched until the satellite runs
}

// Two re-arms before the satellite runs: the first addressed it, the second did not. The posted
// restart must survive the second — the satellite restarts on ANY posted generation past its own.
fn test_a_later_owner_only_rearm_does_not_swallow_a_posted_one() {
	mut own := [16]Record{}
	mut satb := [16]Record{}
	mut remote := [64]Record{}
	mut m := new_module(0x7e3, 0x7e5, 0, true, new_buffer(&own[0], 16, .ring, 50))
	mut cell := FreezeSync{}
	m.set_freeze(&cell)
	mut sat := new_buffer(&satb[0], 16, .ring, 50)
	sat.start()
	sat.push(new_fb(200, 0, 0, 1))
	sat.stop()
	m.on_cmd_multicore(cmd_frame(op_arm, 0x0002), mut sat, 1, &remote[0], 64, zero_clock) // posts gen 1
	m.on_cmd_multicore(cmd_frame(op_arm, 0x0001), mut sat, 1, &remote[0], 64, zero_clock) // gen 2, owner only
	mut sc := Capture{
		buf:       &sat
		freeze:    &cell
		satellite: true
	}
	fb_hook(voidptr(&sc), 0, 0, 1)
	assert sat.state() == .capturing && sat.used() == 1, 'the posted restart was swallowed'
	assert cell.ack == 2
}

// A dump addressing several cores is all-or-nothing: importing the stopped half while the
// other still captures streams one block and strands the host waiting for the second, and
// the inverse order let the owner's block go out alone (codex #271 r7).
fn test_a_two_core_dump_with_one_ring_capturing_is_refused_whole() {
	mut own := [16]Record{}
	mut satb := [16]Record{}
	mut remote := [64]Record{}
	mut m := new_module(0x7e3, 0x7e5, 0, true, new_buffer(&own[0], 16, .ring, 50))
	m.arm()
	mut sat := new_buffer(&satb[0], 16, .ring, 50)
	sat.start()
	for i in 0 .. 3 {
		m.push(new_fb(u16(100 + i), 0, u32(i), 1))
		sat.push(new_fb(u16(200 + i), 0, u32(i), 1))
	}
	m.on_cmd(cmd_frame(op_stop, 0x0001)) // the OWNER stops; the satellite keeps recording
	assert sat.state() == .capturing
	mut drain := can.Frame{}
	assert m.produce(0, mut drain) // the bus loop drains the stop's own response every pass
	imported := m.on_cmd_multicore(cmd_frame(op_dump, 0x0003), mut sat, 1, &remote[0], 64, zero_clock)
	assert !imported
	assert !m.is_dumping(), 'the owner half streamed alone — a partial two-core dump'
	// ...and the refusal names the core that was not ready
	mut f := can.Frame{}
	assert m.produce(0, mut f)
	assert f.data[1] == result_not_ready
	assert f.data[7] == 1 // the satellite's core id
}

// A satellite-only dump of a capturing ring answers not_ready — the tail's unconditional ok
// told the host a block was coming when nothing would ever stream (codex #271 r7).
fn test_a_satellite_only_dump_of_a_capturing_ring_answers_not_ready() {
	mut own := [16]Record{}
	mut satb := [16]Record{}
	mut remote := [64]Record{}
	mut m := new_module(0x7e3, 0x7e5, 0, true, new_buffer(&own[0], 16, .ring, 50))
	mut sat := new_buffer(&satb[0], 16, .ring, 50)
	sat.start()
	sat.push(new_fb(200, 0, 0, 1))
	imported := m.on_cmd_multicore(cmd_frame(op_dump, 0x0002), mut sat, 1, &remote[0], 64, zero_clock)
	assert !imported
	mut f := can.Frame{}
	assert m.produce(0, mut f)
	assert f.data[1] == result_not_ready
}

fn zero_clock() u64 {
	return 0
}

fn clock_1000() u64 {
	return 1000
}

// Self-review on #273: the hook runs AFTER its handler, so a satellite handler that STARTED in the
// window a re-arm ended (start 500) and returned after the re-arm (since 1000) is adopted into the
// new generation by its own hook. When that re-arm restarted the satellite's ring, the dispatch is
// the discarded window's: nothing is recorded into the fresh ring and nothing is raised — the
// over-budget straddler used to freeze the fresh windows on arrival.
fn test_a_dispatch_straddling_a_rearm_that_restarted_its_ring_is_discarded() {
	mut own := [16]Record{}
	mut satb := [16]Record{}
	mut remote := [64]Record{}
	mut m := new_module(0x7e3, 0x7e5, 0, true, new_buffer(&own[0], 16, .ring, 50))
	mut cell := FreezeSync{}
	m.set_freeze(&cell)
	mut sat := new_buffer(&satb[0], 16, .ring, 50)
	sat.start()
	mut sc := satellite_capture(&sat, 0, 10, 100, &cell)
	fb_hook(voidptr(&sc), 0, 100, 10) // one ordinary record in generation 0
	m.on_cmd_multicore(cmd_frame(op_arm, 0x0003), mut sat, 1, &remote[0], 64, clock_1000)
	fb_hook(voidptr(&sc), 0, 500, 900) // started at 500, before the re-arm; 900 us over budget
	assert sat.state() == .capturing && sat.used() == 0, 'the straddler was recorded into the fresh ring'
	assert cell.word == 1 << 1, 'the straddler raised the new generation: ${cell.word}'
	assert cell.ack == 1 // the restart itself was performed and acknowledged
	fb_hook(voidptr(&sc), 0, 1100, 900) // a dispatch that STARTED in the new window trips it
	assert cell.word == (1 << 1) | 1
}

// ...and when the re-arm did NOT address the satellite (owner only), its window continues: the
// straddling dispatch is recorded there and may trip its own ring, but raises nothing — the trip
// predates the generation the owner's fresh window belongs to.
fn test_a_dispatch_straddling_an_owner_only_rearm_is_kept_but_raises_nothing() {
	mut own := [16]Record{}
	mut satb := [16]Record{}
	mut remote := [64]Record{}
	mut m := new_module(0x7e3, 0x7e5, 0, true, new_buffer(&own[0], 16, .ring, 50))
	mut cell := FreezeSync{}
	m.set_freeze(&cell)
	mut sat := new_buffer(&satb[0], 16, .ring, 50)
	sat.start()
	mut sc := satellite_capture(&sat, 0, 10, 100, &cell)
	fb_hook(voidptr(&sc), 0, 100, 10)
	m.on_cmd_multicore(cmd_frame(op_arm, 0x0001), mut sat, 1, &remote[0], 64, clock_1000) // owner only
	fb_hook(voidptr(&sc), 0, 500, 900)
	assert sat.used() >= 2, 'the continuing window lost the straddler'
	assert sat.froze_cause() == freeze_trigger // its own ring may trip
	assert cell.word == 1 << 1, 'the straddler raised the owner-only generation: ${cell.word}'
}

// The satellite's answers while a re-arm is pending describe the window it is about to open —
// status too, not only arm — built without reading the ring the satellite may be restarting.
fn test_status_during_a_pending_rearm_answers_for_the_window_it_opens() {
	mut own := [16]Record{}
	mut satb := [16]Record{}
	mut remote := [64]Record{}
	mut m := new_module(0x7e3, 0x7e5, 0, true, new_buffer(&own[0], 16, .ring, 50))
	mut cell := FreezeSync{}
	m.set_freeze(&cell)
	mut sat := new_buffer(&satb[0], 16, .ring, 50)
	sat.start()
	sat.push(new_fb(200, 0, 0, 1))
	sat.trigger()
	m.on_cmd_multicore(cmd_frame(op_arm, 0x0002), mut sat, 1, &remote[0], 64, zero_clock)
	mut f := can.Frame{}
	for m.produce(0, mut f) {}
	m.on_cmd_multicore(cmd_frame(op_status, 0x0002), mut sat, 1, &remote[0], 64, zero_clock)
	assert m.produce(0, mut f)
	assert f.data[2] & 0x0f == state_code(.capturing), 'status reported the discarded window'
	assert f.data[3] == 0 && f.data[4] == 0
}

// Generations are 31 bits and compared on the circle: across the wrap, a posted re-arm is still
// "after" the satellite's generation, and a performed one is no longer pending.
fn test_generations_compare_across_the_wrap() {
	assert gen_after(0, gen_mask)
	assert gen_after(5, 3)
	assert !gen_after(3, 5)
	assert !gen_after(7, 7)
	mut cell := FreezeSync{}
	mut m := TraceModule{}
	mut ring := [4]Record{}
	m.init(0x7e3, 0x7e5, 0, true, new_buffer(&ring[0], 4, .ring, 50))
	m.set_freeze(&cell)
	m.freeze_gen = gen_mask // the last generation before the wrap
	cell.ack = gen_mask
	cell.rearm = gen_mask
	m.bump(true, zero_clock)
	assert m.freeze_gen == 0 && cell.word == 0 && cell.rearm == 0
	assert m.sat_restart_pending(), 'a re-arm posted across the wrap reads as already performed'
	cell.ack = 0
	assert !m.sat_restart_pending()
}

// codex #285 r1: a stale dispatch raises nothing — but the ring it now records into still honours a
// freeze its adopted generation ALREADY raised (the owner tripped the fresh window meanwhile).
// Returning early skipped that, leaving the satellite capturing past a system freeze.
fn test_a_stale_dispatch_still_honours_a_freeze_already_raised() {
	mut own := [16]Record{}
	mut satb := [16]Record{}
	mut remote := [64]Record{}
	mut m := new_module(0x7e3, 0x7e5, 0, true, new_buffer(&own[0], 16, .ring, 50))
	mut cell := FreezeSync{}
	m.set_freeze(&cell)
	mut sat := new_buffer(&satb[0], 16, .ring, 50)
	sat.start()
	mut sc := satellite_capture(&sat, 0, 10, 100, &cell)
	fb_hook(voidptr(&sc), 0, 100, 10)
	m.on_cmd_multicore(cmd_frame(op_arm, 0x0003), mut sat, 1, &remote[0], 64, clock_1000)
	cell.word = (1 << 1) | 1 // the owner's fresh window tripped before the satellite's hook ran
	fb_hook(voidptr(&sc), 0, 500, 10) // straddler: discarded, but the restarted ring must freeze
	assert sat.used() == 0
	assert sat.froze_cause() == freeze_trigger, 'the fresh satellite ring ignored the raised freeze'
}

// codex #285 r1: a generation is adopted WITH its own stamp. The bump writes the stamp into the
// slot of the generation's parity before the word, so a hook that loaded g1 cannot be handed the
// next generation's boundary (here: g2's stamp already written, g2 not yet published).
fn test_a_generation_is_adopted_with_its_own_stamp() {
	mut cell := FreezeSync{}
	cell.word = 1 << 1 // generation 1 published...
	cell.since[1] = 1000 // ...with its stamp
	cell.since[0] = 5000 // generation 2's stamp already written, its word not yet
	mut ring := [8]Record{}
	mut buf := new_buffer(&ring[0], 8, .ring, 50)
	buf.start()
	mut c := Capture{
		buf:    &buf
		freeze: &cell
	}
	assert c.adopt() == .adopted
	assert c.gen == 1 && c.since == 1000, 'adopted g${c.gen} with stamp ${c.since}'
	// a dispatch that began at 2000 is in g1's window — not "before" it by g2's stamp
	assert c.stale_dispatch(2000, .adopted) == .current
}
