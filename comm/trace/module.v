module trace

import comm.com
import comm.isotp
import driver.can

// TraceModule makes trace an ordinary bus client (see docs/com-modules.md): it owns a capture ring,
// applies routed commands through the existing handle_cmd primitive, and produces the response +
// record stream. The generator routes frames straight to the endpoint handlers (the mechanical
// `on_<endpoint>` convention) — the module never inspects ids; where each port rides on the wire is
// the ecu.toml binding's business.
//
// Two dump wire formats, selected by which endpoints the config binds:
//   - raw:    no `dump_fc` bound — the frozen ring streams as raw 8-byte records on `record`
//             (no flow control needed; candump/decode_trace.py-friendly).
//   - iso-tp: `dump_fc` bound — the ring streams as ONE pack_block payload (header + epoch +
//             records) through an ISO-TP link, flow-controlled by the host on `dump_fc`. This is
//             the format blobly_net's swimlane consumes natively.
pub const endpoints = [
	com.Endpoint{
		name: 'cmd'
		dir:  .rx
		dlc:  8
		doc:  'TraceCmd control (arm/stop/reset/dump/status)'
	},
	com.Endpoint{
		name: 'dump_fc'
		dir:  .rx
		dlc:  8
		doc:  'ISO-TP flow control for the block dump (binding it selects the ISO-TP dump)'
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
		doc:  'the dump stream: raw records, or ISO-TP block frames when dump_fc is bound'
	},
]

pub struct TraceModule {
	rsp_id    u32
	record_id u32
	core      u8
	use_isotp bool // dump_fc bound -> ISO-TP block dump; else the raw record stream
mut:
	buf      TraceBuffer
	link     isotp.Link
	rsp      [8]u8
	rsp_due  bool
	dumping  bool // raw-stream progress
	dump_pos u32  // next record_at() index while a raw dump streams
}

pub fn new_module(rsp_id u32, record_id u32, core u8, use_isotp bool, buf TraceBuffer) TraceModule {
	return TraceModule{
		rsp_id:    rsp_id
		record_id: record_id
		core:      core
		use_isotp: use_isotp
		buf:       buf
	}
}

// on_cmd serves the `cmd` endpoint: apply a routed command frame to our ring via handle_cmd,
// stashing the response for the next produce() and arming the dump stream when one was granted.
pub fn (mut m TraceModule) on_cmd(f can.Frame) {
	if f.len < 8 {
		return // short frame on the wire — never decode stale bytes
	}
	mut b := [8]u8{}
	for i in 0 .. 8 {
		b[i] = f.data[i]
	}
	mut rsp, do_dump, has := handle_cmd(mut m.buf, decode_cmd(b), m.core)
	if do_dump && m.use_isotp && m.link.busy() {
		// the previous dump is still streaming — answer BUSY instead of silently dropping the
		// request (link.send would fail); the host drains/waits and retries.
		rsp[1] = result_busy
		if has {
			m.rsp = rsp
			m.rsp_due = true
		}
		return
	}
	if has {
		m.rsp = rsp
		m.rsp_due = true
	}
	if do_dump {
		if m.use_isotp {
			// One self-describing block (header + preserved epoch + records) into the link;
			// the link segments it and produce() streams the frames, FC-paced by the host.
			mut scratch := [isotp.max_payload]u8{}
			n := m.buf.pack_block(&scratch[0], isotp.max_payload, m.core)
			if n > 0 {
				m.link.send(&scratch[0], n)
			}
		} else {
			m.dumping = true
			m.dump_pos = 0
		}
	}
}

// on_dump_fc serves the `dump_fc` endpoint: the host's ISO-TP flow control for an in-flight dump.
pub fn (mut m TraceModule) on_dump_fc(now u64, f can.Frame) {
	if f.len < 3 {
		return // an FC frame is at least PCI + FS + BS + STmin
	}
	mut p := isotp.Pdu{}
	for i in 0 .. 8 {
		p.data[i] = f.data[i]
	}
	m.link.on_frame(now, p)
}

// produce fills at most ONE tx frame per call and reports whether it did — the bus owner loops
// `for ch.tx_ready() && m.produce(now, mut f) { ch.send(f) }`, so pacing/backpressure stays with
// the channel and the module never blocks or allocates. Priority: the pending command response
// first, then the dump stream (ISO-TP frames or raw records, per the bound endpoints).
pub fn (mut m TraceModule) produce(now u64, mut f can.Frame) bool {
	if m.rsp_due {
		m.rsp_due = false
		fill(mut f, m.rsp_id, m.rsp)
		return true
	}
	if m.use_isotp {
		m.link.tick(now) // advance the N_Bs timeout even when tx_ready gates poll out
		mut p := isotp.Pdu{}
		if m.link.poll(now, mut p) {
			fill(mut f, m.record_id, p.data)
			return true
		}
		return false
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

// load_snapshot imports a window captured OUTSIDE the module in the 8-byte wire form — the
// exec-hook C recorder on an RTOS target: the target glue freezes + snapshots the C ring, then
// loads it here so the protocol (status counts, the dump) serves the real window. The module
// ring ends frozen at n records, oldest first.
pub fn (mut m TraceModule) load_snapshot(src &u8, n u32) {
	m.buf.start()
	for i in 0 .. n {
		mut b := [8]u8{}
		for j in 0 .. 8 {
			b[j] = unsafe { src[i * 8 + u32(j)] }
		}
		m.buf.push(decode_record(b))
	}
	m.buf.stop()
}

// capture / state accessors --------------------------------------------------------------------

// state / rsp_pending / dumping expose the module's control state (accessors for tests + produce()).
pub fn (m TraceModule) state() State {
	return m.buf.state()
}

pub fn (m TraceModule) rsp_pending() bool {
	return m.rsp_due
}

pub fn (m TraceModule) is_dumping() bool {
	return m.dumping || m.link.busy()
}
