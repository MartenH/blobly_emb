module trace

import driver.can

// TraceModule as a bus client: routing (claims), and the control path (a routed command frame drives
// the ring through handle_cmd and leaves a response pending). No channel, no codegen — pure logic.
fn test_trace_module_control_path() {
	mut backing := [8]Record{}
	buf := new_buffer(&backing[0], 8, .ring, 0)
	mut m := new_module(0x712, 0x7e5, 0, buf)

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

fn cmd_frame(id u32, opcode u8) can.Frame {
	mut f := can.Frame{
		id:  id
		len: 8
	}
	f.data[0] = opcode
	return f
}
