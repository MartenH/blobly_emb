module trace

fn rec(id u8) Record {
	return Record{
		handler_id: id
	}
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
