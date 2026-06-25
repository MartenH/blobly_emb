module isotp

import driver.can

// pump runs frames between two paired links until quiescent. a.tx_id == b.rx_id
// and vice-versa, so a poll on one is fed straight to the other.
fn pump(mut a Link, mut b Link, now u64) {
	for _ in 0 .. 4000 {
		mut f := can.Frame{}
		if a.poll(now, mut f) {
			b.on_frame(now, f)
			continue
		}
		if b.poll(now, mut f) {
			a.on_frame(now, f)
			continue
		}
		break
	}
}

fn test_single_frame() {
	mut server := Link{
		rx_id: 0x101
		tx_id: 0x102
	}
	mut tester := Link{
		rx_id: 0x102
		tx_id: 0x101
	}
	req := [u8(0x22), 0xF1, 0x90]
	assert tester.send(&req[0], req.len)
	pump(mut tester, mut server, 1000)

	mut buf := [max_payload]u8{}
	n := server.take(&buf[0])
	assert n == 3
	assert buf[0] == 0x22 && buf[1] == 0xF1 && buf[2] == 0x90
	assert server.take(&buf[0]) == 0 // consumed once
}

fn test_multi_frame_with_blocksize() {
	mut server := Link{
		rx_id: 0x101
		tx_id: 0x102
		bs:    4 // force multiple flow-control rounds
	}
	mut tester := Link{
		rx_id: 0x102
		tx_id: 0x101
	}
	mut req := [max_payload]u8{}
	n := 64
	for i in 0 .. n {
		req[i] = u8(i + 1)
	}
	assert tester.send(&req[0], n)
	pump(mut tester, mut server, 1000)

	mut buf := [max_payload]u8{}
	got := server.take(&buf[0])
	assert got == n
	for i in 0 .. n {
		assert buf[i] == u8(i + 1)
	}
}

fn test_response_direction() {
	mut server := Link{
		rx_id: 0x101
		tx_id: 0x102
	}
	mut tester := Link{
		rx_id: 0x102
		tx_id: 0x101
		bs:    2
	}
	// tester -> server (request), then server -> tester (longer response)
	mut req := [max_payload]u8{}
	for i in 0 .. 20 {
		req[i] = u8(i)
	}
	assert tester.send(&req[0], 20)
	pump(mut tester, mut server, 1000)
	mut rbuf := [max_payload]u8{}
	assert server.take(&rbuf[0]) == 20

	mut resp := [max_payload]u8{}
	m := 100
	for i in 0 .. m {
		resp[i] = u8(0x80 + (i % 16))
	}
	assert server.send(&resp[0], m)
	pump(mut server, mut tester, 1000)

	mut got := [max_payload]u8{}
	rn := tester.take(&got[0])
	assert rn == m
	for i in 0 .. m {
		assert got[i] == u8(0x80 + (i % 16))
	}
}

fn test_send_rejects_when_busy_or_too_long() {
	mut l := Link{
		rx_id: 0x101
		tx_id: 0x102
	}
	mut buf := [max_payload]u8{}
	assert l.send(&buf[0], 10) // starts a tx (FF pending)
	assert !l.send(&buf[0], 5) // busy
	mut l2 := Link{}
	assert !l2.send(&buf[0], max_payload + 1) // too long
}
