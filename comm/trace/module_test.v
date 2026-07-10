module trace

import driver.can

// TraceModule as a bus client: routing (claims), the control path (a routed command frame drives
// the ring through handle_cmd), and the data path (produce streams the response + dump). No channel,
// no codegen — pure logic.
fn test_trace_module_control_path() {
	mut backing := [8]Record{}
	buf := new_buffer(&backing[0], 8, .ring, 0)
	mut m := new_module(0x712, 0x713, 0x7e5, 0, buf)

	// routing: it claims its command id and nothing else
	assert m.claims(0x712)
	assert !m.claims(0x7e5)
	assert !m.claims(0x123)

	// fresh: idle, nothing to send, not dumping
	assert m.state() == .idle
	assert !m.rsp_pending()
	assert !m.is_dumping()

	// arm -> capturing, response due
	m.on_rx(cmd_frame(0x712, op_arm))
	assert m.state() == .capturing
	assert m.rsp_pending()

	// a frame on another id is ignored (belt-and-suspenders vs the router)
	m.on_rx(cmd_frame(0x999, op_stop))
	assert m.state() == .capturing

	// stop -> no longer capturing (frozen/full), still not dumping (nothing to stream yet is fine)
	m.on_rx(cmd_frame(0x712, op_stop))
	assert m.state() != .capturing

	// dump on a stopped buffer arms the stream
	m.on_rx(cmd_frame(0x712, op_dump))
	assert m.is_dumping()
}

// The full bus round trip: arm, capture, stop, dump -> produce yields the pending response frame
// first, then every record chronologically on record_id, then goes dry.
fn test_trace_module_produce_streams_dump() {
	mut backing := [8]Record{}
	buf := new_buffer(&backing[0], 8, .ring, 0)
	mut m := new_module(0x712, 0x713, 0x7e5, 0, buf)

	m.on_rx(cmd_frame(0x712, op_arm))
	mut f := can.Frame{}
	assert m.produce(mut f) // the arm response
	assert f.id == 0x713
	assert f.data[0] == op_arm // opcode echo
	assert !m.produce(mut f) // nothing else pending

	// capture three records through the module's ring
	m.push(new_fb(1, 0, 100, 10))
	m.push(new_fb(2, 0, 200, 20))
	m.push(new_fb(3, 0, 300, 30))

	m.on_rx(cmd_frame(0x712, op_stop))
	assert m.produce(mut f) // the stop response
	assert f.id == 0x713

	m.on_rx(cmd_frame(0x712, op_dump))
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

fn cmd_frame(id u32, opcode u8) can.Frame {
	mut f := can.Frame{
		id:  id
		len: 8
	}
	f.data[0] = opcode
	return f
}
