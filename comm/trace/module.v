module trace

import comm.com
import driver.can

// TraceModule makes trace an ordinary bus client (see docs/com-modules.md): it owns a capture ring,
// applies routed commands through the existing handle_cmd primitive, and produces the response +
// record stream. The generator routes frames straight to the endpoint handlers (the mechanical
// `on_<endpoint>` convention) — the module never inspects ids; where each port rides on the wire is
// the ecu.toml binding's business.

// The endpoint schema: this module's wire ports. Declared as data so the generator can validate the
// ecu.toml [trace] bindings against it and emit the router match. These are the ports the CODE serves
// today; the ISO-TP block dump (`dump_fc` rx) and the HandlerStat heartbeat (`stat` tx) join the list
// when they move in from the old generated protocol.
pub const endpoints = [
	com.Endpoint{
		name: 'cmd'
		dir:  .rx
		dlc:  8
		doc:  'TraceCmd control (arm/stop/reset/dump/status)'
	},
	com.Endpoint{
		name: 'rsp'
		dir:  .tx
		dlc:  8
		doc:  'command response'
	},
	com.Endpoint{
		name: 'record'
		dir:  .tx
		dlc:  8
		doc:  'raw records — the dump stream'
	},
]

pub struct TraceModule {
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

pub fn new_module(rsp_id u32, record_id u32, core u8, buf TraceBuffer) TraceModule {
	return TraceModule{
		rsp_id:    rsp_id
		record_id: record_id
		core:      core
		buf:       buf
	}
}

// on_cmd serves the `cmd` endpoint: apply a routed command frame to our ring via handle_cmd,
// stashing the response for the next produce() and remembering whether a dump was armed.
pub fn (mut m TraceModule) on_cmd(f can.Frame) {
	if f.len < 8 {
		return // short frame on the wire — never decode stale bytes
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
