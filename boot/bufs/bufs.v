module bufs

// The bootloader's message buffers, all sized by its node's maximum message length ([isotp]
// max_message): ONE layout over the one block its glue provides (boards/common/boot_glue.c,
// BOOT_BUF_LEN bytes in gen/boot_gen.h). The generator sizes that block by layout().total and the
// boot image carves it by the same layout, so neither keeps a copy of the arithmetic; the image
// parks when the block it was given is smaller than its layout (a stale boot_gen.h).
//
// Its own module, not module boot's: it reads comm/doip's sizes, and an NVM application that
// imports boot must not compile comm/doip for it.

import comm.doip

// Layout: the offset of each buffer in the block, and the block's length. A buffer starts on a
// 4-byte boundary.
pub struct Layout {
pub:
	req      int // the ISO-TP request (the link reassembles into it): max_message bytes
	rsp      int // the response (the link sends from it): max_message bytes
	net_asm  int // DoIP: the entity's assembly buffer, doip.msg_len(max_message)
	net_in   int // DoIP: a receive chunk, doip.msg_len(max_message)
	net_out  int // DoIP: the response stream, doip.resp_len(max_message)
	net_req  int // DoIP: the mailbox's request on its way to the serve loop, max_message
	net_resp int // DoIP: ... and its answer on the way back, max_message
	total    int // the block's length; the DoIP offsets are 0 (unused) on a bus-only bootloader
}

// layout: the buffers of a bootloader whose connection carries `max_message` bytes, the DoIP ones
// too when it serves DoIP (`net`).
pub fn layout(max_message int, net bool) Layout {
	m := up4(max_message)
	if !net {
		return Layout{
			req:   0
			rsp:   m
			total: 2 * m
		}
	}
	msg := up4(doip.msg_len(max_message))
	out := up4(doip.resp_len(max_message))
	return Layout{
		req:      0
		rsp:      m
		net_asm:  2 * m
		net_in:   2 * m + msg
		net_out:  2 * m + 2 * msg
		net_req:  2 * m + 2 * msg + out
		net_resp: 3 * m + 2 * msg + out
		total:    4 * m + 2 * msg + out
	}
}

fn up4(n int) int {
	return (n + 3) / 4 * 4
}
