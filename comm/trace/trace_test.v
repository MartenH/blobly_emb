module trace

// @verifies REQ-TRACE-011
// The cross-core clock correlation record: signed offset + measurement bound survive the wire,
// and pack_chunk re-states it at the head of every block (module_test.v) so a continuation block
// decodes standalone. The SILICON figure (H755, +49.7 ms) is a bench observation, not asserted here.

// rec is a plain fb.handler run record with a given id (helper for the buffer tests).
fn rec(id u8) Record {
	return new_fb(u16(id), 0, 0, 0)
}

// pack encodes the used records, chronological, 8 bytes each, bounded by out_cap.
fn test_pack_records() {
	mut backing := [4]Record{}
	mut t := new_buffer(&backing[0], 4, .oneshot, 0)
	t.start()
	for i in 0 .. 3 {
		t.push(new_fb(u16(i), 0, u32(i * 100), u16(i)))
	}
	mut out := [64]u8{}
	n := t.pack(&out[0], 64)
	assert n == 24 // 3 records x 8
	// each 8-byte chunk decodes back to its record, in order
	for i in 0 .. 3 {
		mut chunk := [8]u8{}
		for j in 0 .. 8 {
			chunk[j] = out[i * 8 + j]
		}
		r := decode_record(chunk)
		assert r.kind() == kind_fb
		assert r.id() == u16(i)
		assert r.start_us() == u32(i * 100)
		assert r.cpu_us == u16(i)
	}
	// out_cap bounds the write: room for only 2 records
	m := t.pack(&out[0], 20)
	assert m == 16
}

// Record must be a natural 8 bytes (the RAM budget + wire width), and encode/decode must
// round-trip in the documented byte order (b0-1 entity_id, b2 info, b3-5 start_us, b6-7 cpu_us).
fn test_record_is_8_bytes_and_roundtrips() {
	assert sizeof(Record) == 8, 'Record is ${sizeof(Record)} bytes, must be 8'
	r := new_fb(0x234, 0x02, 0x112233, 0x5566) // fb id 0x234, flags 0x02, start (u24), cpu
	b := encode_record(r)
	assert b[0] == 0x34 && b[1] == 0x82 // entity_id LE = (kind_fb<<14) | 0x234 = 0x8234
	assert b[2] == 0x02 // info (flags)
	assert b[3] == 0x33 && b[5] == 0x11 // start_us LE (u24)
	assert b[6] == 0x66 && b[7] == 0x55 // cpu_us LE
	d := decode_record(b)
	assert d == r
	assert d.kind() == kind_fb && d.id() == 0x234
}

// an ISR carries its RAW hardware vector as the 14-bit id — the whole point of the merged
// entity_id: no u8 (256) cap.
fn test_isr_carries_raw_vector() {
	s := new_isr(512, 1000, 20) // vector 512 > 255
	assert s.kind() == kind_isr
	assert s.id() == 512
	assert s.start_us() == 1000 && s.cpu_us == 20
	d := decode_record(encode_record(s))
	assert d.kind() == kind_isr && d.id() == 512
}

// one-shot fills to capacity, stops, and keeps the FIRST N records.
fn test_oneshot_fills_and_stops() {
	mut backing := [4]Record{}
	mut t := new_buffer(&backing[0], 4, .oneshot, 0)
	t.start()
	for i in 0 .. 6 {
		t.push(rec(u8(i)))
	}
	assert t.state() == .full
	assert t.used() == 4
	assert t.record_at(0).id() == 0
	assert t.record_at(3).id() == 3 // 4,5 were dropped after full
}

// ring overwrites oldest and keeps the LAST N records, chronological.
fn test_ring_overwrites_keeps_latest() {
	mut backing := [4]Record{}
	mut t := new_buffer(&backing[0], 4, .ring, 0)
	t.start()
	for i in 0 .. 6 {
		t.push(rec(u8(i)))
	}
	assert t.state() == .capturing // ring keeps running with no trigger
	assert t.used() == 4
	// oldest-first should be 2,3,4,5 (0,1 overwritten)
	assert t.record_at(0).id() == 2
	assert t.record_at(3).id() == 5
}

// ring trigger with pre=50% keeps 2 before + 2 after the trigger, then freezes.
fn test_ring_trigger_pre_post_split() {
	mut backing := [4]Record{}
	mut t := new_buffer(&backing[0], 4, .ring, 50) // pre 2, post 2
	t.start()
	t.push(rec(0)) // A
	t.push(rec(1)) // B
	t.push(rec(2)) // C
	t.trigger() // freeze after 2 more
	assert t.state() == .capturing
	t.push(rec(3)) // D (post 1/2)
	t.push(rec(4)) // E (post 2/2 -> freeze)
	assert t.state() == .frozen
	assert t.used() == 4
	// window = B,C (pre) + D,E (post); A dropped
	assert t.record_at(0).id() == 1
	assert t.record_at(1).id() == 2
	assert t.record_at(2).id() == 3
	assert t.record_at(3).id() == 4
	// pushes after freeze are ignored
	t.push(rec(9))
	assert t.record_at(3).id() == 4
}

// A THREAD record (a context switch to `id`, id 0 = idle) round-trips through the same
// 8-byte cell as an fb run and is distinguishable by kind(); id/reason/time decode back.
fn test_thread_record_roundtrip() {
	s := new_thread(7, reason_preempt, 12345, 200)
	assert s.kind() == kind_thread
	assert !s.is_block_header()
	assert s.id() == 7 // the thread now running
	assert s.info() == reason_preempt // the outgoing thread's fate
	assert s.start_us() == 12345
	assert s.cpu_us == 200
	// survives the wire encode/decode used by pack/dump
	d := decode_record(encode_record(s))
	assert d.kind() == kind_thread && d.id() == 7 && d.info() == reason_preempt
	assert d.start_us() == 12345 && d.cpu_us == 200
	// idle is THREAD id 0
	i := new_idle(reason_block, 500, 60)
	assert i.kind() == kind_thread && i.id() == 0 && i.info() == reason_block
	// a plain fb run is not a block header
	assert !rec(5).is_block_header()
}

// pack_block prepends a self-describing header (core + count) then the records; the count
// reflects what was actually written.
fn test_pack_block_header() {
	mut backing := [4]Record{}
	mut t := new_buffer(&backing[0], 4, .oneshot, 0)
	t.start()
	t.push(rec(10))
	t.push(rec(11))
	t.push(new_thread(1, reason_yield, 500, 10)) // a thread event mixed into the run records
	mut out := [64]u8{}
	n := t.pack_block(&out[0], 64, 2)
	assert n == 8 * 5 // header + LEADING EPOCH (blocks self-anchor) + 3 records
	// first 8 bytes are the block header for core 2, count 3
	mut hb := [8]u8{}
	for i in 0 .. 8 {
		hb[i] = out[i]
	}
	h := decode_record(hb)
	assert h.is_block_header()
	assert h.header_core() == 2
	assert h.header_count() == 4 // the leading self-anchor epoch counts as a record
	// header, then the leading self-anchor epoch, then the first run record
	mut rb := [8]u8{}
	for i in 0 .. 8 {
		rb[i] = out[16 + i]
	}
	assert decode_record(rb).id() == 10
}

// pack_block truncates to out_cap and keeps the header count consistent with what fits.
fn test_pack_block_truncates_consistently() {
	mut backing := [4]Record{}
	mut t := new_buffer(&backing[0], 4, .oneshot, 0)
	t.start()
	for i in 0 .. 4 {
		t.push(rec(u8(i)))
	}
	mut out := [24]u8{} // header + only 2 records fit
	n := t.pack_block(&out[0], 24, 0)
	assert n == 24
	mut hb := [8]u8{}
	for i in 0 .. 8 {
		hb[i] = out[i]
	}
	assert decode_record(hb).header_count() == 2 // count == records actually written
}

// A large block-header count uses all 32 bits (b3-6) — round-trips past a u16.
fn test_block_header_count_is_u32() {
	h := decode_record(encode_record(new_block_header(7, 100000, false)))
	assert h.is_block_header()
	assert h.header_core() == 7
	assert h.header_count() == 100000 // > 65535
}

fn test_epoch_carries_full_u32_base() {
	// A base past the 24-bit start_us range must survive the wire round-trip so long
	// captures re-anchor cleanly (the record itself only holds 24-bit start_us).
	base := u32(0x1234_5678) // > 0xff_ffff
	e := decode_record(encode_record(new_epoch(base)))
	assert e.is_epoch()
	assert !e.is_block_header()
	assert e.epoch_base() == base
	assert e.kind() == kind_control
}

// REQ-TRACE-011. The satellite is released AFTER the bus owner, so its clock reads less at the
// same instant and the offset is NEGATIVE — the sign has to survive the wire or the host shifts
// the lane the wrong way, which looks plausible and is exactly backwards.
fn test_core_offset_carries_signed_offset_and_bound() {
	off := i32(-1_250_000) // satellite trails the owner by 1.25 s
	r := decode_record(encode_record(new_core_offset(off, 37)))
	assert r.is_core_offset()
	assert !r.is_epoch() && !r.is_block_header()
	assert r.kind() == kind_control
	assert r.core_offset_us() == off
	assert r.core_offset_bound_us() == 37

	// and the other direction, past the 24-bit range, so the high byte is really carried
	pos := i32(0x00ab_cdef)
	p := decode_record(encode_record(new_core_offset(pos, 0)))
	assert p.core_offset_us() == pos
	assert p.core_offset_bound_us() == 0
}

// When an epoch record ages out of a ring while records that depend on it survive, the dump
// must still carry that base — pack() leads with a synthetic epoch that REPLACES the oldest
// slot, so the record count stays == used (matching TraceRsp.records_used).
fn test_ring_preserves_evicted_epoch_base() {
	base := u32(0x0200_0000) // past one u24 wrap
	mut backing := [4]Record{}
	mut t := new_buffer(&backing[0], 4, .ring, 0)
	t.start()
	t.push(new_epoch(base)) // origin for what follows
	t.push(new_fb(1, 0, 10, 5))
	t.push(new_fb(2, 0, 20, 5))
	t.push(new_fb(3, 0, 30, 5)) // ring full: [epoch, fb1, fb2, fb3]
	t.push(new_fb(4, 0, 40, 5)) // evicts the epoch; ring = [fb1, fb2, fb3, fb4]
	mut out := [64]u8{}
	n := t.pack(&out[0], 64)
	assert n == 8 * 4 // epoch replaces the oldest (fb1): epoch + fb2,fb3,fb4 == used records
	mut hb := [8]u8{}
	for j in 0 .. 8 {
		hb[j] = out[j]
	}
	lead := decode_record(hb)
	assert lead.is_epoch()
	assert lead.epoch_base() == base // the aged-out base is preserved
	// the first real record after it is fb2 (fb1 was replaced by the base epoch)
	mut rb := [8]u8{}
	for j in 0 .. 8 {
		rb[j] = out[8 + j]
	}
	first := decode_record(rb)
	assert first.kind() == kind_fb && first.id() == 2
}

// A prefix must not clobber a NEWER epoch still in the ring: pack() replaces only the oldest
// slot, so an in-buffer epoch is retained and re-anchors the records after it.
fn test_prefixed_pack_retains_inner_epoch() {
	b1 := u32(0x0100_0000)
	b2 := u32(0x0200_0000)
	mut backing := [4]Record{}
	mut t := new_buffer(&backing[0], 4, .ring, 0)
	t.start()
	t.push(new_epoch(b1)) // B1
	t.push(new_fb(1, 0, 10, 5)) // base B1
	t.push(new_epoch(b2)) // B2, in-buffer
	t.push(new_fb(2, 0, 20, 5)) // base B2; ring full: [epochB1, fb1, epochB2, fb2]
	t.push(new_fb(3, 0, 30, 5)) // evicts epochB1 -> prefix=B1; ring=[fb1, epochB2, fb2, fb3]
	mut out := [64]u8{}
	n := t.pack(&out[0], 64)
	assert n == 8 * 4 // epoch(B1) replaces fb1; then in-buffer epochB2, fb2, fb3 retained
	// decode the stream: B1 prefix, then the in-buffer B2 epoch must survive
	mut recs := []Record{}
	for k in 0 .. 4 {
		mut cb := [8]u8{}
		for j in 0 .. 8 {
			cb[j] = out[k * 8 + j]
		}
		recs << decode_record(cb)
	}
	assert recs[0].is_epoch() && recs[0].epoch_base() == b1
	assert recs[1].is_epoch() && recs[1].epoch_base() == b2 // NOT dropped
	assert recs[2].kind() == kind_fb && recs[2].id() == 2
	assert recs[3].kind() == kind_fb && recs[3].id() == 3
}

// Once a newer epoch becomes the oldest in-buffer record, the carried prefix is stale and must
// be dropped — otherwise pack() prepends a redundant epoch and steals a record slot.
fn test_ring_clears_stale_prefix_when_newer_epoch_anchors() {
	mut backing := [4]Record{}
	mut t := new_buffer(&backing[0], 4, .ring, 0)
	t.start()
	t.push(new_epoch(0x0100_0000)) // B1
	t.push(new_fb(1, 0, 10, 5))
	t.push(new_fb(2, 0, 20, 5))
	t.push(new_fb(3, 0, 30, 5)) // full
	t.push(new_epoch(0x0200_0000)) // B2 evicts the B1 epoch -> prefix = B1
	t.push(new_fb(4, 0, 40, 5))
	t.push(new_fb(5, 0, 50, 5))
	t.push(new_fb(6, 0, 60, 5)) // B2 epoch is now the oldest -> stale prefix cleared
	mut out := [64]u8{}
	n := t.pack(&out[0], 64)
	assert n == 8 * 4 // in-buffer epoch(B2) + fb4,fb5,fb6 — no synthetic prefix
	mut hb := [8]u8{}
	for j in 0 .. 8 {
		hb[j] = out[j]
	}
	e := decode_record(hb)
	assert e.is_epoch()
	assert e.epoch_base() == 0x0200_0000 // the live in-buffer epoch, not the stale B1
}

// The base epoch replaces the OLDEST slot (never the newest), so the most recent window is
// kept and the total stays == used records.
fn test_prefixed_pack_replaces_oldest_slot() {
	mut backing := [4]Record{}
	mut t := new_buffer(&backing[0], 4, .ring, 0)
	t.start()
	t.push(new_epoch(0x0200_0000))
	t.push(new_fb(1, 0, 10, 5))
	t.push(new_fb(2, 0, 20, 5))
	t.push(new_fb(3, 0, 30, 5))
	t.push(new_fb(4, 0, 40, 5)) // evict epoch -> prefix; ring = [fb1, fb2, fb3, fb4]
	mut out := [64]u8{} // ample room — the epoch still replaces fb1, not adds to it
	n := t.pack(&out[0], 64)
	assert n == 32 // epoch + fb2,fb3,fb4 == 4 records (== used)
	mut hb := [8]u8{}
	for j in 0 .. 8 {
		hb[j] = out[j]
	}
	assert decode_record(hb).is_epoch() // base still leads
	mut r1 := [8]u8{}
	for j in 0 .. 8 {
		r1[j] = out[8 + j]
	}
	assert decode_record(r1).id() == 2 // fb1 (oldest) dropped, fb2 first
	mut rlast := [8]u8{}
	for j in 0 .. 8 {
		rlast[j] = out[24 + j]
	}
	assert decode_record(rlast).id() == 4 // newest preserved
}
