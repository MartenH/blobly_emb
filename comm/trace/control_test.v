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
	b0, d0 := handle_cmd(mut tb, Cmd{ opcode: op_status }, 0)
	assert !d0
	assert decode_rsp(b0).state == 0 // idle
	assert decode_rsp(b0).capacity == 4

	// arm -> capturing
	b1, _ := handle_cmd(mut tb, Cmd{ opcode: op_arm }, 0)
	assert decode_rsp(b1).state == 1 // capturing
	assert tb.state() == .capturing

	// fill it, then status shows full
	for i in 0 .. 4 {
		tb.push(Record{ handler_id: u8(i) })
	}
	b2, _ := handle_cmd(mut tb, Cmd{ opcode: op_status }, 0)
	assert decode_rsp(b2).state == 2 // full
	assert decode_rsp(b2).records_used == 4

	// dump is requested (caller streams it) and the rsp echoes the opcode
	b3, d3 := handle_cmd(mut tb, Cmd{ opcode: op_dump }, 0)
	assert d3
	assert decode_rsp(b3).opcode_echo == op_dump

	// an unknown opcode is rejected
	b4, _ := handle_cmd(mut tb, Cmd{ opcode: 99 }, 0)
	assert decode_rsp(b4).result == result_bad_opcode
}
