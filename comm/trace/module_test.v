module trace

// @verifies REQ-TRACE-011

import comm.isotp
import driver.can

// REQ-TRACE-011. The satellite's window is only comparable to ours once its clock offset rides
// with it, so load_remote leads the block with that record — but ONLY when it was measured.
// Emitting a 0 offset for an unmeasured core would claim the two cores are perfectly correlated,
// the precise false precision this record exists to remove.
fn test_load_remote_leads_with_measured_core_offset() {
	mut backing := [8]Record{}
	mut rbacking := [8]Record{}
	buf := new_buffer(&backing[0], 8, .ring, 0)
	mut m := new_module(0x713, 0x7e5, 0, true, buf)
	m.set_remote(1, &rbacking[0], 8)

	mut wire := [8]u8{}
	e := encode_record(new_fb(9, 0, 111, 5))
	for j in 0 .. 8 {
		wire[j] = e[j]
	}

	// never measured -> the window imports bare, no correlation claimed
	m.load_remote(&wire[0], 1)
	assert m.remote.used() == 1
	assert !m.remote.record_at(0).is_core_offset()

	// measured -> the offset leads, and the imported records still all arrive after it
	m.set_core_offset(-1_250_000, 42)
	m.load_remote(&wire[0], 1)
	assert m.remote.used() == 2
	lead := m.remote.record_at(0)
	assert lead.is_core_offset()
	assert lead.core_offset_us() == -1_250_000
	assert lead.core_offset_bound_us() == 42
	assert m.remote.record_at(1).kind() == kind_fb
}

// REQ-TRACE-011. A satellite window spans several blocks (bench: 5 for a 256-record ring), but the
// offset record is pushed ONCE at the head of the window — so every later block must re-state it
// the way pack_chunk already re-states the epoch. Without this a host that decodes blocks
// independently correlates block 1 and silently renders the rest on the wrong clock.
fn test_pack_chunk_restates_core_offset_in_every_block() {
	mut backing := [8]Record{}
	mut t := new_buffer(&backing[0], 8, .oneshot, 0)
	t.start()
	t.push(new_core_offset(-1_250_000, 42))
	for i in 0 .. 7 {
		t.push(new_fb(u16(i), 0, u32(100 + i), 5))
	}
	t.stop()

	// 32-byte cap = header + epoch + offset + ONE record, so the window needs several chunks
	mut out := [32]u8{}
	mut from := u32(0)
	mut blocks := 0
	for {
		n, next, more := t.pack_chunk(&out[0], 32, 1, from)
		assert n > 0
		blocks++
		// every block: header, epoch, then the offset — restated, never dropped
		assert decode_record_at(out, 0).is_block_header()
		assert decode_record_at(out, 1).is_epoch()
		off := decode_record_at(out, 2)
		assert off.is_core_offset(), 'block ${blocks} lost the core offset'
		assert off.core_offset_us() == -1_250_000
		assert off.core_offset_bound_us() == 42
		from = next
		if !more {
			break
		}
	}
	assert blocks > 1, 'test needs a multi-block window to be meaningful'
}

fn decode_record_at(out [32]u8, i int) Record {
	mut b := [8]u8{}
	for j in 0 .. 8 {
		b[j] = out[i * 8 + j]
	}
	return decode_record(b)
}

// The endpoint schema is data the generator consumes: rx ports get an on_<name> method (checked by
// the generated code compiling), tx ports become constructor bindings. Guard the invariants here.
fn test_endpoint_schema() {
	assert endpoints.len == 4
	mut names := []string{}
	for e in endpoints {
		names << e.name
		assert e.dlc == 8
	}
	assert names == ['cmd', 'dump_fc', 'rsp', 'record']
	assert endpoints[0].dir == .rx
	assert endpoints[1].dir == .rx
	assert endpoints[2].dir == .tx
	assert endpoints[3].dir == .tx
}

// TraceModule as a bus client: the control path (a routed command frame drives the ring through
// handle_cmd) and the data path (produce streams the response + dump). No channel, no codegen.
fn test_trace_module_control_path() {
	mut backing := [8]Record{}
	buf := new_buffer(&backing[0], 8, .ring, 0)
	mut m := new_module(0x713, 0x7e5, 0, false, buf)

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
	mut m := new_module(0x713, 0x7e5, 0, false, buf)

	m.on_cmd(cmd_frame(op_arm))
	mut f := can.Frame{}
	assert m.produce(0, mut f) // the arm response
	assert f.id == 0x713
	assert f.data[0] == op_arm // opcode echo
	assert !m.produce(0, mut f) // nothing else pending

	// capture three records through the module's ring
	m.push(new_fb(1, 0, 100, 10))
	m.push(new_fb(2, 0, 200, 20))
	m.push(new_fb(3, 0, 300, 30))

	m.on_cmd(cmd_frame(op_stop))
	assert m.produce(0, mut f) // the stop response
	assert f.id == 0x713

	m.on_cmd(cmd_frame(op_dump))
	assert m.produce(0, mut f) // the dump response (ok)
	assert f.id == 0x713
	assert f.data[1] == result_ok

	// then the records, oldest first, raw on record_id
	mut ids := []u16{}
	for m.produce(0, mut f) {
		assert f.id == 0x7e5
		ids << u16(f.data[0]) | (u16(f.data[1]) << 8)
	}
	assert ids.len == 3
	assert !m.is_dumping() // stream drained
	assert !m.produce(0, mut f) // and stays dry
}

// The FB hook family: fb_hook (installed via sched.set_trace_hook) pushes fb records into the
// module's ring; over budget it flags + freezes (the flight-recorder trigger).
fn test_fb_hook_records_and_triggers() {
	mut backing := [8]Record{}
	// pre_pct 100: keep the whole pre-trigger window -> the trigger freezes immediately
	buf := new_buffer(&backing[0], 8, .ring, 100)
	mut m := new_module(0x713, 0x7e5, 0, false, buf)
	m.on_cmd(cmd_frame(op_arm))
	mut cap := m.capture(10, 500, 1_000_000) // id_base 10, budget 500 us

	fb_hook(&cap, 0, 1_000_100, 120) // handler 0, 120 us — fine
	fb_hook(&cap, 2, 1_001_100, 700) // handler 2, 700 us — over budget: flag + freeze
	assert cap.fb_count == 2
	assert m.state() == .frozen

	m.on_cmd(cmd_frame(op_dump))
	mut f := can.Frame{}
	assert m.produce(0, mut f) // rsp
	assert m.produce(0, mut f) // record 1: fb id 10, no flags
	assert u16(f.data[0]) | (u16(f.data[1]) << 8) == entity(kind_fb, 10)
	assert m.produce(0, mut f) // record 2: fb id 12, overran flag
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

// The ISO-TP block dump: dump_fc bound -> the frozen ring streams as ONE pack_block payload
// through the link, flow-controlled by a host-side Link — the format blobly_net consumes.
fn test_trace_module_isotp_block_dump() {
	mut backing := [8]Record{}
	buf := new_buffer(&backing[0], 8, .ring, 0)
	mut m := new_module(0x713, 0x7e5, 0, true, buf)

	m.on_cmd(cmd_frame(op_arm))
	mut f := can.Frame{}
	assert m.produce(0, mut f) // arm rsp
	m.push(new_fb(1, 0, 100, 10))
	m.push(new_fb(2, 0, 200, 20))
	m.on_cmd(cmd_frame(op_stop))
	assert m.produce(0, mut f) // stop rsp
	m.on_cmd(cmd_frame(op_dump))
	assert m.produce(0, mut f) // dump rsp
	assert f.id == 0x713

	// host side: an isotp.Link reassembles what the module streams on record_id
	mut host := isotp.Link{}
	mut now := u64(1000)
	for _ in 0 .. 64 {
		if m.produce(now, mut f) {
			assert f.id == 0x7e5
			mut p := isotp.Pdu{}
			for j in 0 .. 8 {
				p.data[j] = f.data[j]
			}
			host.on_frame(now, p)
		}
		// route the host's FC back to the module's dump_fc endpoint
		mut fc := isotp.Pdu{}
		if host.poll(now, mut fc) {
			mut fcf := can.Frame{
				id:  0x7e6
				len: 8
			}
			for j in 0 .. 8 {
				fcf.data[j] = fc.data[j]
			}
			m.on_dump_fc(now, fcf)
		}
		now += 1000
	}
	mut block := [520]u8{}
	n := host.take(&block[0])
	assert n == 8 + 8 + 2 * 8 // header + leading epoch (blocks self-anchor) + 2 records
	// header, epoch, then the two fb records in wire form
	r1 := decode_record([block[16], block[17], block[18], block[19], block[20], block[21],
		block[22], block[23]]!)
	assert r1.entity_id == entity(kind_fb, 1)
	assert !m.is_dumping() // link drained
}

// load_snapshot: the exec-hook target path — raw 8-byte records captured in C land in the module
// ring as a frozen window, so status counts and the dump serve the real capture.
fn test_load_snapshot_imports_wire_records() {
	mut backing := [8]Record{}
	buf := new_buffer(&backing[0], 8, .ring, 0)
	mut m := new_module(0x713, 0x7e5, 0, false, buf)

	mut raw := [24]u8{} // 3 records in wire form
	for i in 0 .. 3 {
		b := encode_record(new_thread(u16(i + 1), reason_yield, u32(i * 100), u16(i * 10)))
		for j in 0 .. 8 {
			raw[i * 8 + j] = b[j]
		}
	}
	m.load_snapshot(&raw[0], 3)
	assert m.state() != .capturing // frozen window
	m.on_cmd(cmd_frame(op_status))
	mut f := can.Frame{}
	assert m.produce(0, mut f) // status rsp
	assert u16(f.data[3]) | (u16(f.data[4]) << 8) == 3 // records_used = 3

	m.on_cmd(cmd_frame(op_dump))
	assert m.produce(0, mut f) // dump rsp
	mut ids := []u16{}
	for m.produce(0, mut f) {
		ids << u16(f.data[0]) | (u16(f.data[1]) << 8)
	}
	assert ids.len == 3
	assert ids[0] == entity(kind_thread, 1)
}

// Multi-image dump: a satellite core's imported snapshot streams as its OWN block after the
// local one — two sequential ISO-TP transfers, each self-describing (block header carries the
// core), exactly what blobly_net's per-core decoder already consumes.
fn test_remote_block_streams_after_local() {
	mut backing := [8]Record{}
	buf := new_buffer(&backing[0], 8, .ring, 0)
	mut m := new_module(0x713, 0x7e5, 0, true, buf)
	mut rbacking := [8]Record{}
	m.set_remote(1, &rbacking[0], 8)

	// local capture: one fb record; remote snapshot: two wire-form records from "core 1"
	m.on_cmd(cmd_frame(op_arm))
	mut f := can.Frame{}
	assert m.produce(0, mut f)
	m.push(new_fb(1, 0, 100, 10))
	m.on_cmd(cmd_frame(op_stop))
	assert m.produce(0, mut f)
	m.on_cmd(cmd_frame(op_dump))
	assert m.produce(0, mut f) // dump rsp
	mut wire := [16]u8{}
	e1 := encode_record(new_fb(9, 0, 111, 5))
	e2 := encode_record(new_fb(9, 0, 222, 6))
	for j in 0 .. 8 {
		wire[j] = e1[j]
		wire[8 + j] = e2[j]
	}
	m.load_remote(&wire[0], 2)
	assert m.is_dumping() // remote queued keeps the owner pacing

	// host reassembles BOTH transfers back to back
	mut host := isotp.Link{}
	mut now := u64(1000)
	mut blocks := 0
	mut cores := []u8{}
	mut counts := []u32{}
	for _ in 0 .. 256 {
		if m.produce(now, mut f) {
			mut p := isotp.Pdu{}
			for j in 0 .. 8 {
				p.data[j] = f.data[j]
			}
			host.on_frame(now, p)
		}
		mut fc := isotp.Pdu{}
		if host.poll(now, mut fc) {
			mut fcf := can.Frame{
				id:  0x7e6
				len: 8
			}
			for j in 0 .. 8 {
				fcf.data[j] = fc.data[j]
			}
			m.on_dump_fc(now, fcf)
		}
		mut block := [520]u8{}
		n := host.take(&block[0])
		if n > 0 {
			blocks++
			hdr := decode_record([block[0], block[1], block[2], block[3], block[4], block[5],
				block[6], block[7]]!)
			assert hdr.is_block_header()
			cores << hdr.header_core()
			counts << u32((n - 8) / 8)
		}
		now += 1000
	}
	assert blocks == 2
	assert cores == [u8(0), 1] // local first, then the satellite's block
	assert counts == [u32(2), 3] // each block: leading epoch + its records
	assert !m.is_dumping()
}

// Multi-BLOCK dump: a window deeper than one ISO-TP payload streams as continuation blocks
// (header more-flag set until the last), each self-anchored by a leading epoch — the ring is
// no longer capped by the transport payload, and the block stream is transport-neutral.
fn test_multiblock_local_and_remote() {
	mut backing := [128]Record{}
	buf := new_buffer(&backing[0], 128, .ring, 0)
	mut m := new_module(0x713, 0x7e5, 0, true, buf)
	mut rbacking := [128]Record{}
	m.set_remote(1, &rbacking[0], 128)

	m.on_cmd(cmd_frame(op_arm))
	mut f := can.Frame{}
	assert m.produce(0, mut f)
	for i in 0 .. 100 { // > 63: needs two local blocks
		m.push(new_fb(u16(i % 8), 0, u32(100 + i), 3))
	}
	m.on_cmd(cmd_frame(op_stop))
	assert m.produce(0, mut f)
	m.on_cmd(cmd_frame(op_dump))
	assert m.produce(0, mut f) // dump rsp
	mut wire := [70 * 8]u8{}
	for i in 0 .. 70 { // remote window: > 63, needs two blocks too
		e := encode_record(new_fb(u16(9), 0, u32(500 + i), 2))
		for j in 0 .. 8 {
			wire[i * 8 + j] = e[j]
		}
	}
	m.load_remote(&wire[0], 70)

	mut host := isotp.Link{}
	mut now := u64(1000)
	mut cores := []u8{}
	mut mores := []bool{}
	mut recs := []u32{}
	for _ in 0 .. 4096 {
		if m.produce(now, mut f) {
			mut p := isotp.Pdu{}
			for j in 0 .. 8 {
				p.data[j] = f.data[j]
			}
			host.on_frame(now, p)
		}
		mut fc := isotp.Pdu{}
		if host.poll(now, mut fc) {
			mut fcf := can.Frame{
				id:  0x7e6
				len: 8
			}
			for j in 0 .. 8 {
				fcf.data[j] = fc.data[j]
			}
			m.on_dump_fc(now, fcf)
		}
		mut block := [520]u8{}
		n := host.take(&block[0])
		if n > 0 {
			hdr := decode_record([block[0], block[1], block[2], block[3], block[4], block[5],
				block[6], block[7]]!)
			assert hdr.is_block_header()
			cores << hdr.header_core()
			mores << hdr.header_more()
			recs << u32((n - 8) / 8)
		}
		now += 1000
	}
	// local window (100 recs + leading epochs) = 2 blocks, then the remote (70) = 2 blocks
	assert cores == [u8(0), 0, 1, 1]
	assert mores == [true, false, true, false] // end-of-stream lives IN the format
	assert recs[0] == 64 // epoch + 63 records fills one payload
	assert recs[0] + recs[1] == 102 // 100 records + one leading epoch per block
	assert recs[2] + recs[3] == 72 // 70 + 2 epochs
	assert !m.is_dumping()
}
