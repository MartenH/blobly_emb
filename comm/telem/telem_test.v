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
