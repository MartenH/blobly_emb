module trace

// Cmd/Rsp round-trip through the wire codec.
fn test_cmd_rsp_roundtrip() {
	c := Cmd{
		opcode:         op_dump
		arg0:           1
		period_ms:      1000
		handler_filter: 0xFFFF
	}
	assert decode_cmd(encode_cmd(c)) == c
	r := Rsp{
		opcode_echo:  op_status
		result:       result_ok
		state:        2
		records_used: 4096
		capacity:     4096
		core:         1
	}
	assert decode_rsp(encode_rsp(r)) == r
}

// handle_cmd drives the buffer through its lifecycle and reports state/used/capacity.
fn test_handle_cmd_lifecycle() {
	mut backing := [4]Record{}
	mut tb := new_buffer(&backing[0], 4, .oneshot, 0)

	// status on an idle buffer
	b0, d0, _ := handle_cmd(mut tb, Cmd{ opcode: op_status }, 0)
	assert !d0
	assert decode_rsp(b0).state == 0 // idle
	assert decode_rsp(b0).capacity == 4

	// arm -> capturing
	b1, _, _ := handle_cmd(mut tb, Cmd{ opcode: op_arm }, 0)
	assert decode_rsp(b1).state == 1 // capturing
	assert tb.state() == .capturing

	// dump while still capturing is rejected (buffer is being written)
	bnr, dnr, _ := handle_cmd(mut tb, Cmd{ opcode: op_dump }, 0)
	assert !dnr
	assert decode_rsp(bnr).result == result_not_ready

	// set_push is a known opcode that isn't implemented -> unsupported
	bsp, _, _ := handle_cmd(mut tb, Cmd{ opcode: op_set_push }, 0)
	assert decode_rsp(bsp).result == result_unsupported

	// fill it, then status shows full
	for i in 0 .. 4 {
		tb.push(new_fb(u16(i), 0, 0, 0))
	}
	b2, _, _ := handle_cmd(mut tb, Cmd{ opcode: op_status }, 0)
	assert decode_rsp(b2).state == 2 // full
	assert decode_rsp(b2).records_used == 4

	// dump is requested (caller streams it) and the rsp echoes the opcode
	b3, d3, _ := handle_cmd(mut tb, Cmd{ opcode: op_dump }, 0)
	assert d3
	assert decode_rsp(b3).opcode_echo == op_dump

	// an unknown opcode is rejected
	b4, _, _ := handle_cmd(mut tb, Cmd{ opcode: 99 }, 0)
	assert decode_rsp(b4).result == result_bad_opcode
}

// op_stop freezes a ring immediately at the current fill (not a delayed pre/post freeze).
fn test_stop_freezes_ring_now() {
	mut backing := [8]Record{}
	mut tb := new_buffer(&backing[0], 8, .ring, 50)
	tb.start()
	tb.push(new_fb(1, 0, 0, 0))
	tb.push(new_fb(2, 0, 0, 0))
	handle_cmd(mut tb, Cmd{ opcode: op_stop }, 0)
	assert tb.state() == .frozen
	assert tb.used() == 2 // frozen right here, no extra post-trigger records
}

// core_mask round-trips through b6-7 and targets() selects the right cores; a zero mask
// means the single receiving core (core 0) for back-compat with pre-multicore commands.
fn test_core_mask() {
	c := decode_cmd(encode_cmd(Cmd{ opcode: op_dump, core_mask: 0b0101 }))
	assert c.core_mask == 0b0101
	assert c.targets(0)
	assert !c.targets(1)
	assert c.targets(2)
	assert !c.targets(3)
	// zero mask -> only core 0 (existing single-core commands left b6-7 zero)
	z := Cmd{
		opcode: op_status
	}
	assert z.targets(0)
	assert !z.targets(1)
}

// handle_cmd enforces core_mask: a command that doesn't select this core is ignored
// (addressed=false, no mutation); one that does is applied.
fn test_handle_cmd_respects_core_mask() {
	mut backing := [4]Record{}
	mut tb := new_buffer(&backing[0], 4, .oneshot, 0)
	tb.start()
	// stop addressed to core 1 only (mask 0x0002) must not touch core 0's buffer
	_, _, addressed := handle_cmd(mut tb, Cmd{ opcode: op_stop, core_mask: 0x0002 }, 0)
	assert !addressed
	assert tb.state() == .capturing // untouched
	// the same stop addressed to core 0 (mask 0x0001) is applied
	_, _, addr0 := handle_cmd(mut tb, Cmd{ opcode: op_stop, core_mask: 0x0001 }, 0)
	assert addr0
	assert tb.state() == .full // oneshot stop -> full
}
