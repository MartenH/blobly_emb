module trace

fn rec(id u8) Record {
	return Record{
		handler_id: id
	}
}

// pack encodes the used records, chronological, 8 bytes each, bounded by out_cap.
fn test_pack_records() {
	mut backing := [4]Record{}
	mut t := new_buffer(&backing[0], 4, .oneshot, 0)
	t.start()
	for i in 0 .. 3 {
		t.push(Record{
			handler_id: u8(i)
			start_us:   u32(i * 100)
			cpu_us:     u16(i)
		})
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
		assert r.handler_id == u8(i)
		assert r.start_us == u32(i * 100)
		assert r.cpu_us == u16(i)
	}
	// out_cap bounds the write: room for only 2 records
	m := t.pack(&out[0], 20)
	assert m == 16
}

// Record must be a natural 8 bytes (the RAM budget + wire width), and encode/decode must
// round-trip in the documented byte order.
fn test_record_is_8_bytes_and_roundtrips() {
	assert sizeof(Record) == 8, 'Record is ${sizeof(Record)} bytes, must be 8'
	r := Record{
		start_us:   0x11223344
		cpu_us:     0x5566
		handler_id: 7
		flags:      0x02
	}
	b := encode_record(r)
	assert b[0] == 7 // handler_id
	assert b[1] == 0x02 // flags
	assert b[2] == 0x44 && b[5] == 0x11 // start_us LE
	assert b[6] == 0x66 && b[7] == 0x55 // cpu_us LE
	d := decode_record(b)
	assert d == r
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
	assert t.record_at(0).handler_id == 0
	assert t.record_at(3).handler_id == 3 // 4,5 were dropped after full
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
	assert t.record_at(0).handler_id == 2
	assert t.record_at(3).handler_id == 5
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
	assert t.record_at(0).handler_id == 1
	assert t.record_at(1).handler_id == 2
	assert t.record_at(2).handler_id == 3
	assert t.record_at(3).handler_id == 4
	// pushes after freeze are ignored
	t.push(rec(9))
	assert t.record_at(3).handler_id == 4
}

// A thread-switch record round-trips through the same 8-byte cell as a run record and is
// distinguishable by is_switch(); the from/to/reason fields decode back.
fn test_switch_record_roundtrip() {
	s := new_switch(12345, 3, 7, switch_preempt)
	assert s.is_switch()
	assert !s.is_header()
	assert s.to_thread() == 7
	assert s.from_thread() == 3
	assert s.reason() == switch_preempt
	assert s.start_us == 12345
	// survives the wire encode/decode used by pack/dump
	d := decode_record(encode_record(s))
	assert d.is_switch()
	assert d.from_thread() == 3 && d.to_thread() == 7 && d.reason() == switch_preempt
	assert d.start_us == 12345
	// a plain run record is neither switch nor header
	assert !rec(5).is_switch() && !rec(5).is_header()
}

// pack_block prepends a self-describing header (core + count) then the records; the count
// reflects what was actually written.
fn test_pack_block_header() {
	mut backing := [4]Record{}
	mut t := new_buffer(&backing[0], 4, .oneshot, 0)
	t.start()
	t.push(rec(10))
	t.push(rec(11))
	t.push(new_switch(500, 0, 1, switch_resume))
	mut out := [64]u8{}
	n := t.pack_block(&out[0], 64, 2)
	assert n == 8 * 4 // header + 3 records
	// first 8 bytes are the block header for core 2, count 3
	mut hb := [8]u8{}
	for i in 0 .. 8 {
		hb[i] = out[i]
	}
	h := decode_record(hb)
	assert h.is_header()
	assert h.header_core() == 2
	assert h.header_count() == 3
	// second record cell is the first run record
	mut rb := [8]u8{}
	for i in 0 .. 8 {
		rb[i] = out[8 + i]
	}
	assert decode_record(rb).handler_id == 10
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
