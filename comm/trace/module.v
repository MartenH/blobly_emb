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
	rsp_id    u32
	record_id u32
	core      u8
mut:
	buf      TraceBuffer
	rsp      [8]u8
	rsp_due  bool
	dumping  bool
	dump_pos u32 // next record_at() index while a dump streams
}

pub fn new_module(cmd_id u32, rsp_id u32, record_id u32, core u8, buf TraceBuffer) TraceModule {
	return TraceModule{
		cmd_id:    cmd_id
		rsp_id:    rsp_id
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
		m.dump_pos = 0
	}
}

// produce fills at most ONE tx frame per call and reports whether it did — the bus owner loops
// `for ch.tx_ready() && m.produce(mut f) { ch.send(f) }`, so pacing/backpressure stays with the
// channel and the module never blocks or allocates. Priority: the pending command response first,
// then the armed dump streamed one record per frame (raw 8-byte records on record_id, chronological
// oldest-first — the same wire format the ThreadX exec-hook stream uses).
pub fn (mut m TraceModule) produce(mut f can.Frame) bool {
	if m.rsp_due {
		m.rsp_due = false
		fill(mut f, m.rsp_id, m.rsp)
		return true
	}
	if m.dumping {
		if m.dump_pos >= m.buf.used() {
			m.dumping = false
			return false
		}
		fill(mut f, m.record_id, encode_record(m.buf.record_at(m.dump_pos)))
		m.dump_pos++
		return true
	}
	return false
}

fn fill(mut f can.Frame, id u32, b [8]u8) {
	f.id = id
	f.len = 8
	for i in 0 .. 8 {
		f.data[i] = b[i]
	}
}

// push feeds the module's ring — this is where the three enter/exit hook families (ISR, thread, FB)
// deliver their timestamped records. The hooks own WHEN; the module owns the ring and the bus side.
pub fn (mut m TraceModule) push(r Record) {
	m.buf.push(r)
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
