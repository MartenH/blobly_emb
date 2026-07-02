module telem

// @verifies REQ-TELEM-002
// Per-core loads round-trip through the CpuLoad payload as percent, clamped.
fn test_cpuload_roundtrip() {
	mut load := [cpuload_max_cores]u16{}
	load[0] = 34 // 3.4%
	load[1] = 14 // 1.4%
	load[2] = 16 // 1.6%
	load[3] = 999 // 99.9% -> 99
	b := encode_cpuload(load, 4)
	assert decode_cpuload(b, 0) == 3
	assert decode_cpuload(b, 1) == 1
	assert decode_cpuload(b, 2) == 1
	assert decode_cpuload(b, 3) == 99
	// cores past ncores stay zero
	assert decode_cpuload(b, 4) == 0
}

// A core reading over 100% (multiple busy schedulers summed) clamps to 100.
fn test_clamp_over_100() {
	mut load := [cpuload_max_cores]u16{}
	load[0] = 1500 // 150% -> clamp
	b := encode_cpuload(load, 1)
	assert b[0] == 100
}

// ncores beyond the frame width is bounded, never writes past 8 bytes.
fn test_ncores_bounded() {
	mut load := [cpuload_max_cores]u16{}
	for i in 0 .. cpuload_max_cores {
		load[i] = u16(100 * (i + 1)) // 10%,20%,...
	}
	b := encode_cpuload(load, 99) // absurd ncores
	assert b[0] == 10
	assert b[7] == 80
}

// HandlerStat round-trips through encode/decode, and durations past the u16 range
// saturate with the saturated flag set.
fn test_handlerstat_roundtrip() {
	b := encode_handlerstat(5, trace_flag_overran, 1234, 5678, 42)
	d := decode_handlerstat(b)
	assert d.handler_id == 5
	assert d.flags == trace_flag_overran
	assert d.last_us == 1234
	assert d.max_us == 5678
	assert d.count_delta == 42
}

fn test_handlerstat_saturates() {
	b := encode_handlerstat(0, 0, 70000, 100, 99999) // last_us + count past u16
	d := decode_handlerstat(b)
	assert d.last_us == 0xFFFF, 'last should clamp'
	assert d.flags & trace_flag_saturated != 0, 'saturated flag set'
	assert d.count_delta == 0xFFFF, 'count should clamp'
	assert d.max_us == 100
	// a clamped count alone (durations in range) must still flag saturation, so a host
	// tool never mistakes the clamp for an exact 65535 invocations.
	b2 := encode_handlerstat(0, 0, 100, 200, 70000)
	d2 := decode_handlerstat(b2)
	assert d2.count_delta == 0xFFFF
	assert d2.flags & trace_flag_saturated != 0, 'count clamp must set saturated'
	assert d2.last_us == 100
}
