module isotp

// Normal fixed addressing's identifiers (ISO 15765-2 §10.3.3), as golden vectors — blobly_net's
// system-model reader (blobly/sysview addressing_test.v) pins the same ones, so the tester and the
// node derive one id from one pair of addresses.
// @verifies REQ-CAN-TP-041 REQ-CAN-TP-043

fn test_normal_fixed_ids_are_0x18da_target_source() {
	assert fixed_id(false, 0x10, 0xF1) == u32(0x18DA10F1) // a request to node 0x10 from tester 0xF1
	assert fixed_id(false, 0xF1, 0x10) == u32(0x18DAF110) // its answer
	assert fixed_id(true, 0x33, 0xF1) == u32(0x18DB33F1) // a functional request to 0x33
	assert fixed_id(false, 0x00, 0xFF) == u32(0x18DA00FF)
	assert fixed_id(false, 0xFF, 0x00) == u32(0x18DAFF00)
}

fn test_normal_fixed_ids_are_priority_6_and_29_bit() {
	for functional in [false, true] {
		for t in [u8(0), 0x10, 0x33, 0xF1, 0xFF] {
			for s in [u8(0), 0x10, 0xF1, 0xFF] {
				id := fixed_id(functional, t, s)
				assert id >> 26 == fixed_priority
				assert id <= ext_id_max
				assert id > std_id_max // never an 11-bit id, so never taken for one
			}
		}
	}
}
