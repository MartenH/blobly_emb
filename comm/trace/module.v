module trace

import driver.can

// TraceModule makes trace an ordinary bus client (see docs/com-modules.md): it owns a capture ring,
// claims its command frame id, applies routed commands through the existing handle_cmd primitive, and
// produces the response + record stream. This is the interface every capability shares — trace, NM,
// telemetry all look like {claims, on_rx, produce}; the bus owner iterates them and names none.
//
// This file lands the CONTROL path (routing -> handle_cmd -> pending response). The record/dump
// streaming is produce()'s remaining job; kept small on purpose, since handle_cmd already is the logic.
pub struct TraceModule {
	cmd_id    u32
	record_id u32
	core      u8
mut:
	buf     TraceBuffer
	rsp     [8]u8
	rsp_due bool
	dumping bool
}

pub fn new_module(cmd_id u32, record_id u32, core u8, buf TraceBuffer) TraceModule {
	return TraceModule{
		cmd_id:    cmd_id
		record_id: record_id
		core:      core
		buf:       buf
	}
}

// claims reports whether a frame id routes to this module (the routing table dispatches on it).
pub fn (m TraceModule) claims(id u32) bool {
	return id == m.cmd_id
}

// on_rx applies a routed command frame to our ring via handle_cmd, stashing the response for the next
// produce() and remembering whether a dump was armed.
pub fn (mut m TraceModule) on_rx(f can.Frame) {
	if f.id != m.cmd_id {
		return
	}
	mut b := [8]u8{}
	for i in 0 .. 8 {
		b[i] = f.data[i]
	}
	rsp, do_dump, has := handle_cmd(mut m.buf, decode_cmd(b), m.core)
	if has {
		m.rsp = rsp
		m.rsp_due = true
	}
	if do_dump {
		m.dumping = true
	}
}

// state / rsp_pending / dumping expose the module's control state (accessors for tests + produce()).
pub fn (m TraceModule) state() State {
	return m.buf.state()
}

pub fn (m TraceModule) rsp_pending() bool {
	return m.rsp_due
}

pub fn (m TraceModule) is_dumping() bool {
	return m.dumping
}
