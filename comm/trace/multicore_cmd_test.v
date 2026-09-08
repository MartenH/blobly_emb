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

// A dump must freeze the satellite before reading it. The owner cannot ask the host to send a
// separate stop first: a window still being written by the other core would stream as a moving
// target, which is exactly the incoherence the multi-core view exists to avoid.
fn test_dump_freezes_a_capturing_satellite_before_importing() {
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
	m.on_cmd(cmd_frame(op_stop, 0xffff)) // owner's own ring: stopped, so its dump is legal
	assert sat.state() == .capturing, 'precondition: the satellite is still recording'

	imported := m.on_cmd_multicore(cmd_frame(op_dump, 0x0003), mut sat, 1, &remote[0], 64)

	assert imported, 'the satellite window was not imported'
	assert sat.state() == .frozen || sat.state() == .full, 'the satellite was read while capturing'
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
	m.on_cmd(cmd_frame(op_stop, 0xffff))
	assert m.on_cmd_multicore(cmd_frame(op_dump, 0x0003), mut sat, 1, &remote[0], 64)

	// the remote window holds core 1's ids (200..), not the owner's (100..)
	assert m.remote.used() == 3, 'expected 3 imported records, got ${m.remote.used()}'
	assert m.remote_core == 1
	for i in 0 .. 3 {
		assert m.remote.record_at(u32(i)).id() == u16(200 + i)
	}
}
