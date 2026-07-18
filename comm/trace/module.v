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
mut:
	rsp_id    u32
	record_id u32
	core      u8
	use_isotp bool // dump_fc bound -> ISO-TP block dump; else the raw record stream
	buf      TraceBuffer
	link     isotp.Link
	rsp      [8]u8
	rsp_due  bool
	dumping  bool // raw-stream progress
	dump_pos u32  // next record_at() index while a raw dump streams
	// A SATELLITE core's imported window (multi-image targets): the bus owner fetches the
	// remote core's frozen snapshot over shared memory, loads it here, and produce() streams
	// it as that core's OWN self-describing block once the local block's transfer completes —
	// the host reads one ISO-TP transfer per core (mask_popcount blocks), decoder unchanged.
	remote      TraceBuffer
	remote_core u8
	remote_due  bool
	remote_from u32 // continuation cursor into the remote window
	// local ISO-TP dump continuation: the window streams as SELF-DESCRIBING ~one-payload
	// blocks (header carries a more-flag; each block re-anchors with an epoch), so the ring
	// is no longer capped by one transfer — and the same block stream rides any future
	// transport binding (Ethernet/DoIP) unchanged.
	local_due  bool
	local_from u32
	// pack scratch — a full ISO-TP payload. The module lives in __global on target, so this
	// is bss; a [isotp.max_payload]u8 STACK local in produce() overran the 4 KB comm stack
	// (baseline ~2.6 K) the moment a dump ran (see stack-copy-boot-hang).
	scratch [isotp.max_payload]u8
}

// new_module builds a module by VALUE — host use only (a spacious stack). On target the
// module lives in __global and MUST be built in place: it carries an ISO-TP link (~1 KB),
// the remote import buffer, and a full-payload scratch — a return-copy of all that overran
// the 4 KB comm stack at boot (stack-copy-boot-hang; TraceModule was the 'survived by luck'
// case that note warned about — the scratch field finally tipped it). Use init() on target.
pub fn new_module(rsp_id u32, record_id u32, core u8, use_isotp bool, buf TraceBuffer) TraceModule {
	mut m := TraceModule{}
	m.init(rsp_id, record_id, core, use_isotp, buf)
	return m
}

// init constructs the module IN PLACE (no module-sized stack copy) — the target path.
pub fn (mut m TraceModule) init(rsp_id u32, record_id u32, core u8, use_isotp bool, buf TraceBuffer) {
	m.link.init_defaults() // _vinit never runs on target: timeouts are set HERE
	m.rsp_id = rsp_id
	m.record_id = record_id
	m.core = core
	m.use_isotp = use_isotp
	m.buf = buf
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
			// stream the window as continuation blocks; produce() packs + sends each one as
			// the previous transfer completes (multi-block: the ring outgrows one payload)
			m.local_due = true
			m.local_from = 0
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
		if !m.link.busy() {
			// the previous transfer completed: send the next continuation block — the local
			// window first, then the satellite's, each block its own FC-handshaked transfer
			if m.local_due {
				n, next, more := m.buf.pack_chunk(&m.scratch[0], isotp.max_payload, m.core,
					m.local_from)
				m.local_from = next
				m.local_due = more
				if n > 0 {
					m.link.send(&m.scratch[0], n)
				}
			} else if m.remote_due {
				n, next, more := m.remote.pack_chunk(&m.scratch[0], isotp.max_payload,
					m.remote_core, m.remote_from)
				m.remote_from = next
				m.remote_due = more
				if n > 0 {
					m.link.send(&m.scratch[0], n)
				}
			}
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

// set_remote wires the import buffer for ONE satellite core (caller-owned backing, like
// new_buffer) — the single-dump-owner rule: remote cores never touch the bus themselves.
pub fn (mut m TraceModule) set_remote(core u8, backing &Record, capacity u32) {
	m.remote = new_buffer(backing, capacity, .oneshot, 0)
	m.remote_core = core
}

// load_remote imports the satellite's snapshot (wire-form records, oldest first) and queues
// it as the next dump block. Call after the LOCAL dump was granted; produce() sequences it.
pub fn (mut m TraceModule) load_remote(src &u8, n u32) {
	m.remote.start()
	for i in 0 .. n {
		mut b := [8]u8{}
		for j in 0 .. 8 {
			b[j] = unsafe { src[i * 8 + u32(j)] }
		}
		m.remote.push(decode_record(b))
	}
	m.remote.stop()
	m.remote_due = true
	m.remote_from = 0
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
	return m.dumping || m.link.busy() || m.remote_due || m.local_due
}
