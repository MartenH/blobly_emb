module bufs

import comm.doip

// @verifies REQ-BOOT-020
// the layout's totals are what the generator sizes the block by: two messages on a bus-only
// bootloader, the DoIP entity's buffers beside them on a [doip] one, each on a 4-byte boundary
fn test_the_layout_holds_every_buffer() {
	assert layout(520, false).total == 1040
	assert layout(4095, false).total == 8192 // 4095 rounded to 4096, twice
	l := layout(520, true)
	assert l.rsp == 520 && l.net_asm == 1040
	assert l.net_in == l.net_asm + doip.msg_len(520)
	assert l.net_out == l.net_in + doip.msg_len(520)
	assert l.net_req == l.net_out + up4(doip.resp_len(520)) // 545, rounded up
	assert l.net_resp == l.net_req + 520
	assert l.total == l.net_resp + 520
	for m in [8, 66, 520, 4095] {
		for net in [false, true] {
			k := layout(m, net)
			for off in [k.req, k.rsp, k.net_asm, k.net_in, k.net_out, k.net_req, k.net_resp, k.total] {
				assert off % 4 == 0
			}
			assert k.rsp >= m
			if net {
				assert k.net_resp + m <= k.total
			}
		}
	}
}
