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

	imported := m.on_cmd_multicore(cmd_frame(op_dump, 0x0003), mut sat, 1, &remote[0], 64)

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
	m.on_cmd_multicore(cmd_frame(op_stop, 0x0003), mut sat, 1, &remote[0], 64)
	assert sat.state() != .capturing, 'stop did not reach the satellite'

	assert m.on_cmd_multicore(cmd_frame(op_dump, 0x0003), mut sat, 1, &remote[0], 64)
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
	assert m.on_cmd_multicore(cmd_frame(op_dump, 0x0003), mut sat, 1, &remote[0], 64)

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

	m.on_cmd_multicore(cmd_frame(op_arm, 0xffff), mut sat, 1, &remote[0], 64)

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

	m.on_cmd_multicore(cmd_frame(op_stop, 0x0001), mut sat, 1, &remote[0], 64)

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

	imported := m.on_cmd_multicore(cmd_frame(op_dump, 0x0003), mut sat, 1, &remote[0], 64)

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
	m.on_cmd_multicore(cmd_frame(op_stop, 0x0003), mut sat, 1, &remote[0], 64)
	assert m.on_cmd_multicore(cmd_frame(op_dump, 0x0003), mut sat, 1, &remote[0], 64)

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

	m.on_cmd_multicore(cmd_frame(op_status, 0x0002), mut sat, 1, &remote[0], 64)

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

	m.on_cmd_multicore(cmd_frame(op_status, 0x0003), mut sat, 1, &remote[0], 64)

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
	m.on_cmd_multicore(cmd_frame(op_stop, 0x0003), mut sat, 1, &remote[0], 64)
	assert m.on_cmd_multicore(cmd_frame(op_dump, 0x0003), mut sat, 1, &remote[0], 64)
	assert m.is_streaming(), 'precondition: a dump is queued'
	// drain the first dump's response the way the bus loop does each pass, so the busy answer
	// below is not refused by queue_rsp's don't-overwrite rule
	mut f := can.Frame{}
	m.produce(1000, mut f)
	assert !m.rsp_pending()

	// second dump, while blocks are still queued
	imported := m.on_cmd_multicore(cmd_frame(op_dump, 0x0003), mut sat, 1, &remote[0], 64)

	assert !imported, 'the satellite window was re-imported mid-stream'
	assert m.rsp_pending(), 'the refused dump was not answered'
	assert decode_rsp(m.rsp).result == result_busy, 'expected BUSY, got ${decode_rsp(m.rsp).result}'
}

// An arm/start/reset RETIRES the shared cross-core freeze, whichever cores the mask names, and
// does so before any ring restarts — retired after (or keyed on the owner's state, as the runner
// once did), a peer dispatching in the gap re-froze the just-armed ring from the stale cell, and
// an arm addressed to the satellite alone never cleared it at all (codex #271 r2).
fn test_an_arm_retires_the_shared_freeze_for_any_mask() {
	mut ring := [64]Record{}
	mut m := TraceModule{}
	m.init(0x7e3, 0x7e5, 0, true, new_buffer(&ring[0], 64, .ring, 50))
	mut cell := u32(1) // a trigger froze the system earlier
	m.set_freeze(&cell)
	mut sat_ring := [64]Record{}
	mut sat := new_buffer(&sat_ring[0], 64, .ring, 50)
	mut remote := [65]Record{}
	m.on_cmd_multicore(cmd_frame(op_arm, 0x0002), mut sat, 1, &remote[0], 65) // satellite ALONE
	assert cell == 0
	cell = 1
	m.on_cmd_multicore(cmd_frame(op_dump, 0x0003), mut sat, 1, &remote[0], 65)
	assert cell == 1 // a dump consumes nothing: the frozen system stays described by the cell
	m.on_cmd_multicore(cmd_frame(op_reset, 0x0003), mut sat, 1, &remote[0], 65)
	assert cell == 0
}
