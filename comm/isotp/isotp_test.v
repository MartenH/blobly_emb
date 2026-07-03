module isotp

// pump runs PDUs between two links until quiescent — each link's output is the
// other's input (the bridge does this id-routing on a real bus).
fn pump(mut a Link, mut b Link, now u64) {
	for _ in 0 .. 4000 {
		mut p := Pdu{}
		if a.poll(now, mut p) {
			b.on_frame(now, p)
			continue
		}
		if b.poll(now, mut p) {
			a.on_frame(now, p)
			continue
		}
		break
	}
}

fn test_single_frame() {
	mut server := Link{}
	mut tester := Link{}
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
		bs: 4 // force multiple flow-control rounds
	}
	mut tester := Link{}
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
	mut server := Link{}
	mut tester := Link{
		bs: 2
	}
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

fn test_wait_fc_times_out() {
	// A multi-frame tx that never gets a FC (no receiver bound) must abort after N_Bs
	// so the link frees up instead of wedging busy forever.
	mut l := Link{
		n_bs_us: 1000
	}
	mut buf := [max_payload]u8{}
	assert l.send(&buf[0], 20) // > 7 bytes -> FF then wait_fc

	mut p := Pdu{}
	assert l.poll(0, mut p) // emits the FF, enters wait_fc (deadline = 0 + 1000)
	assert !l.poll(500, mut p) // still waiting, before the deadline
	assert !l.send(&buf[0], 5) // busy: no FC yet
	assert !l.poll(1000, mut p) // deadline reached -> abort to idle
	assert l.send(&buf[0], 5) // link is free again
}

fn test_fc_wait_refreshes_n_bs() {
	// FC.WAIT means "not ready yet" — it must restart N_Bs so a peer that WAITs within
	// the window and later sends CTS still completes, instead of aborting at the old deadline.
	mut l := Link{
		n_bs_us: 1000
	}
	mut buf := [max_payload]u8{}
	for i in 0 .. 20 {
		buf[i] = u8(i + 1)
	}
	assert l.send(&buf[0], 20)
	mut p := Pdu{}
	assert l.poll(0, mut p) // FF -> wait_fc (deadline 1000)

	mut wait := Pdu{}
	wait.data[0] = 0x31 // FC.WAIT
	l.on_frame(900, wait) // WAIT just before the old deadline -> refresh to 900+1000
	assert !l.poll(1500, mut p) // past old deadline but within refreshed one: still waiting

	mut cts := Pdu{}
	cts.data[0] = 0x30 // FC.CTS, bs=0, stmin=0
	l.on_frame(1500, cts)
	assert l.poll(1500, mut p) // now sends the first CF
	assert (p.data[0] & 0xF0) == 0x20
}

fn test_fc_wait_bounded_by_wftmax() {
	// An endless-WAIT peer must not re-wedge the link: after wft_max WAITs the tx aborts.
	mut l := Link{
		n_bs_us: 1000
		wft_max: 3
	}
	mut buf := [max_payload]u8{}
	assert l.send(&buf[0], 20)
	mut p := Pdu{}
	assert l.poll(0, mut p) // FF -> wait_fc

	mut wait := Pdu{}
	wait.data[0] = 0x31
	for _ in 0 .. 3 {
		l.on_frame(10, wait) // 3 WAITs tolerated
	}
	assert !l.send(&buf[0], 5) // still busy after the 3rd
	l.on_frame(10, wait) // 4th WAIT exceeds wft_max -> abort
	assert l.send(&buf[0], 5) // link freed
}

fn test_send_rejects_when_busy_or_too_long() {
	mut l := Link{}
	mut buf := [max_payload]u8{}
	assert l.send(&buf[0], 10) // starts a tx (FF pending)
	assert !l.send(&buf[0], 5) // busy
	mut l2 := Link{}
	assert !l2.send(&buf[0], max_payload + 1) // too long
}
