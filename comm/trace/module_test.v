module trace

import driver.can

// The endpoint schema is data the generator consumes: rx ports get an on_<name> method (checked by
// the generated code compiling), tx ports become constructor bindings. Guard the invariants here.
fn test_endpoint_schema() {
	assert endpoints.len == 3
	mut names := []string{}
	for e in endpoints {
		names << e.name
		assert e.dlc == 8
	}
	assert names == ['cmd', 'rsp', 'record']
	assert endpoints[0].dir == .rx // cmd is the only rx port today
	assert endpoints[1].dir == .tx
	assert endpoints[2].dir == .tx
}

// TraceModule as a bus client: the control path (a routed command frame drives the ring through
// handle_cmd) and the data path (produce streams the response + dump). No channel, no codegen.
fn test_trace_module_control_path() {
	mut backing := [8]Record{}
	buf := new_buffer(&backing[0], 8, .ring, 0)
	mut m := new_module(0x713, 0x7e5, 0, buf)

	// fresh: idle, nothing to send, not dumping
	assert m.state() == .idle
	assert !m.rsp_pending()
	assert !m.is_dumping()

	// arm -> capturing, response due
	m.on_cmd(cmd_frame(op_arm))
	assert m.state() == .capturing
	assert m.rsp_pending()

	// a short frame is ignored (never decode stale bytes)
	mut short := cmd_frame(op_stop)
	short.len = 4
	m.on_cmd(short)
	assert m.state() == .capturing

	// stop -> no longer capturing; dump on a stopped buffer arms the stream
	m.on_cmd(cmd_frame(op_stop))
	assert m.state() != .capturing
	m.on_cmd(cmd_frame(op_dump))
	assert m.is_dumping()
}

// The full bus round trip: arm, capture, stop, dump -> produce yields the pending response frame
// first, then every record chronologically on record_id, then goes dry.
fn test_trace_module_produce_streams_dump() {
	mut backing := [8]Record{}
	buf := new_buffer(&backing[0], 8, .ring, 0)
	mut m := new_module(0x713, 0x7e5, 0, buf)

	m.on_cmd(cmd_frame(op_arm))
	mut f := can.Frame{}
	assert m.produce(mut f) // the arm response
	assert f.id == 0x713
	assert f.data[0] == op_arm // opcode echo
	assert !m.produce(mut f) // nothing else pending

	// capture three records through the module's ring
	m.push(new_fb(1, 0, 100, 10))
	m.push(new_fb(2, 0, 200, 20))
	m.push(new_fb(3, 0, 300, 30))

	m.on_cmd(cmd_frame(op_stop))
	assert m.produce(mut f) // the stop response
	assert f.id == 0x713

	m.on_cmd(cmd_frame(op_dump))
	assert m.produce(mut f) // the dump response (ok)
	assert f.id == 0x713
	assert f.data[1] == result_ok

	// then the records, oldest first, raw on record_id
	mut ids := []u16{}
	for m.produce(mut f) {
		assert f.id == 0x7e5
		ids << u16(f.data[0]) | (u16(f.data[1]) << 8)
	}
	assert ids.len == 3
	assert !m.is_dumping() // stream drained
	assert !m.produce(mut f) // and stays dry
}

// The FB hook family: fb_hook (installed via sched.set_trace_hook) pushes fb records into the
// module's ring; over budget it flags + freezes (the flight-recorder trigger).
fn test_fb_hook_records_and_triggers() {
	mut backing := [8]Record{}
	// pre_pct 100: keep the whole pre-trigger window -> the trigger freezes immediately
	buf := new_buffer(&backing[0], 8, .ring, 100)
	mut m := new_module(0x713, 0x7e5, 0, buf)
	m.on_cmd(cmd_frame(op_arm))
	mut cap := m.capture(10, 500, 1_000_000) // id_base 10, budget 500 us

	fb_hook(&cap, 0, 1_000_100, 120) // handler 0, 120 us — fine
	fb_hook(&cap, 2, 1_001_100, 700) // handler 2, 700 us — over budget: flag + freeze
	assert cap.fb_count == 2
	assert m.state() == .frozen

	m.on_cmd(cmd_frame(op_dump))
	mut f := can.Frame{}
	assert m.produce(mut f) // rsp
	assert m.produce(mut f) // record 1: fb id 10, no flags
	assert u16(f.data[0]) | (u16(f.data[1]) << 8) == entity(kind_fb, 10)
	assert m.produce(mut f) // record 2: fb id 12, overran flag
	assert u16(f.data[0]) | (u16(f.data[1]) << 8) == entity(kind_fb, 12)
	assert f.data[2] & flag_overran != 0
}

fn cmd_frame(opcode u8) can.Frame {
	mut f := can.Frame{
		id:  0x712
		len: 8
	}
	f.data[0] = opcode
	return f
}
