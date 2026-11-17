module main

// The sim takes a request frame as the bootloader's serve step does (diag.serve_step): on the
// request id in the connection's format only — a 29-bit frame with the same id number is another
// node's, and must neither be served nor end a transfer in progress.
// @verifies REQ-CAN-TP-042

fn test_only_the_request_id_in_its_format_is_a_request() {
	assert is_request(req_id, false, 8)
	assert !is_request(req_id, true, 8) // 0x000007B0 as a 29-bit id: not this connection's
	assert !is_request(rsp_id, false, 8)
	assert !is_request(req_id, false, 0)
	assert !is_request(req_id, false, 65)
	assert is_request(req_id, false, 64)
}
