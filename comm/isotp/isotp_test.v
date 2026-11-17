module isotp

// @verifies REQ-CAN-TP-001 REQ-CAN-TP-002 REQ-CAN-TP-003 REQ-CAN-TP-004 REQ-CAN-TP-005 REQ-CAN-TP-007 REQ-CAN-TP-008 REQ-CAN-TP-009
// @verifies REQ-CAN-TP-006 REQ-CAN-TP-010 REQ-CAN-TP-011 REQ-CAN-TP-012 REQ-CAN-TP-013 REQ-CAN-TP-014 REQ-CAN-TP-015
// @verifies REQ-CAN-TP-016 REQ-CAN-TP-017 REQ-CAN-TP-018
// (segmentation/reassembly: single/first/consecutive frames, sequence wrap, blocksize, STmin, both
//  directions; flow control incl. WAIT bounds, N_Bs/N_Cr timeouts, sequence errors, unexpected and
//  truncated frames, reserved STmin, undefined flow status, overflow, the length bound, busy
//  refusal, abort counting and abort_tx.)

// bound gives a link `cap`-byte receive and transmit buffers of its own (the owner's job)
fn bound(l Link, cap int) Link {
	mut b := l
	rx := []u8{len: cap}
	tx := []u8{len: cap}
	b.bind_rx(&rx[0], cap)
	assert b.bind_tx(&tx[0], cap)
	return b
}

// pdu: a received frame of exactly these bytes (its length is theirs)
fn pdu(b []u8) Pdu {
	mut p := Pdu{
		len: b.len
	}
	for i, x in b {
		p.data[i] = x
	}
	return p
}

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
	mut server := bound(Link{}, default_message)
	mut tester := bound(Link{}, default_message)
	req := [u8(0x22), 0xF1, 0x90]
	assert tester.send(&req[0], req.len)
	pump(mut tester, mut server, 1000)

	mut buf := [default_message]u8{}
	n := server.take(&buf[0])
	assert n == 3
	assert buf[0] == 0x22 && buf[1] == 0xF1 && buf[2] == 0x90
	assert server.take(&buf[0]) == 0 // consumed once
}

// A Consecutive Frame with the wrong sequence number (a dropped/reordered frame) aborts the
// reassembly instead of misassembling it — nothing becomes ready — and a fresh First Frame on the
// same link resyncs cleanly. (The host-side receiver in blobly_net enforces the same invariant;
// this is the target end of that contract.)
fn test_cf_sequence_mismatch_aborts_then_resyncs() {
	mut l := bound(Link{}, default_message)
	mut buf := [default_message]u8{}

	// First Frame (total 14, first 6 bytes) -> receiving, expecting CF SN 1.
	l.on_frame(0, pdu([u8(0x10), 14, 1, 2, 3, 4, 5, 6]))
	// A CF with SN 2 (expected 1) -> sequence error -> abort.
	l.on_frame(0, pdu([u8(0x22), 7, 8, 9, 10, 11, 12, 13]))
	assert l.take(&buf[0]) == 0 // aborted, not misassembled — nothing ready

	// The same link resyncs on a fresh First Frame (total 9) + a correctly-numbered CF (SN 1).
	l.on_frame(0, pdu([u8(0x10), 9, 0xA0, 0xB0, 0xC0, 0xD0, 0xE0, 0xF0]))
	l.on_frame(0, pdu([u8(0x21), 0x11, 0x22, 0x33, 0, 0, 0, 0]))
	got := l.take(&buf[0])
	assert got == 9
	assert buf[0] == 0xA0 && buf[5] == 0xF0 && buf[6] == 0x11 && buf[8] == 0x33
}

fn test_multi_frame_with_blocksize() {
	mut server := bound(Link{
		bs: 4 // force multiple flow-control rounds
	}, default_message)
	mut tester := bound(Link{}, default_message)
	mut req := [default_message]u8{}
	n := 64
	for i in 0 .. n {
		req[i] = u8(i + 1)
	}
	assert tester.send(&req[0], n)
	pump(mut tester, mut server, 1000)

	mut buf := [default_message]u8{}
	got := server.take(&buf[0])
	assert got == n
	for i in 0 .. n {
		assert buf[i] == u8(i + 1)
	}
}

fn test_response_direction() {
	mut server := bound(Link{}, default_message)
	mut tester := bound(Link{
		bs: 2
	}, default_message)
	mut req := [default_message]u8{}
	for i in 0 .. 20 {
		req[i] = u8(i)
	}
	assert tester.send(&req[0], 20)
	pump(mut tester, mut server, 1000)
	mut rbuf := [default_message]u8{}
	assert server.take(&rbuf[0]) == 20

	mut resp := [default_message]u8{}
	m := 100
	for i in 0 .. m {
		resp[i] = u8(0x80 + (i % 16))
	}
	assert server.send(&resp[0], m)
	pump(mut server, mut tester, 1000)

	mut got := [default_message]u8{}
	rn := tester.take(&got[0])
	assert rn == m
	for i in 0 .. m {
		assert got[i] == u8(0x80 + (i % 16))
	}
}

fn test_wait_fc_times_out() {
	// A multi-frame tx that never gets a FC (no receiver bound) must abort after N_Bs
	// so the link frees up instead of wedging busy forever.
	mut l := bound(Link{
		n_bs_us: 1000
	}, default_message)
	mut buf := [default_message]u8{}
	assert l.send(&buf[0], 20) // > 7 bytes -> FF then wait_fc

	mut p := Pdu{}
	assert l.poll(0, mut p) // emits the FF, enters wait_fc (deadline = 0 + 1000)
	assert !l.poll(500, mut p) // still waiting, before the deadline
	assert !l.send(&buf[0], 5) // busy: no FC yet
	assert !l.poll(1000, mut p) // deadline reached -> abort to idle
	assert l.send(&buf[0], 5) // link is free again
}

fn test_tick_times_out_stalled_send_cf() {
	// In send_cf (CTS received) a full Tx FIFO gates poll() out mid-burst; tick() must still
	// abort if no CF goes out within N_Bs, so a bus drop mid-transfer can't wedge the link.
	mut l := bound(Link{
		n_bs_us: 1000
	}, default_message)
	mut buf := [default_message]u8{}
	for i in 0 .. 20 {
		buf[i] = u8(i + 1)
	}
	assert l.send(&buf[0], 20)
	mut p := Pdu{}
	assert l.poll(0, mut p) // FF -> wait_fc
	mut cts := Pdu{}
	cts.data[0] = 0x30 // FC.CTS, bs=0, stmin=0 -> send_cf (deadline 0+1000)
	l.on_frame(0, cts)
	assert l.poll(0, mut p) // one CF out; 7 bytes left -> stays send_cf, deadline refreshed
	assert (p.data[0] & 0xF0) == 0x20
	l.tick(500) // FIFO "full": poll gated out; before the deadline -> still busy
	assert !l.send(&buf[0], 5)
	l.tick(1000) // deadline reached in send_cf via tick -> abort
	assert l.send(&buf[0], 5) // free again
}

fn test_tick_times_out_wait_fc_without_poll() {
	// Under Tx back-pressure the sender gates poll() on FIFO space, so the N_Bs timeout must
	// also advance via tick() alone — otherwise a full FIFO (down bus) wedges the link forever.
	mut l := bound(Link{
		n_bs_us: 1000
	}, default_message)
	mut buf := [default_message]u8{}
	assert l.send(&buf[0], 20)
	mut p := Pdu{}
	assert l.poll(0, mut p) // FF out, enter wait_fc (deadline 1000)
	l.tick(500) // before the deadline: still busy
	assert !l.send(&buf[0], 5)
	l.tick(1000) // deadline reached via tick (poll never called) -> abort
	assert l.send(&buf[0], 5) // free again
}

fn test_fc_wait_refreshes_n_bs() {
	// FC.WAIT means "not ready yet" — it must restart N_Bs so a peer that WAITs within
	// the window and later sends CTS still completes, instead of aborting at the old deadline.
	mut l := bound(Link{
		n_bs_us: 1000
	}, default_message)
	mut buf := [default_message]u8{}
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

fn test_wftmax_255_does_not_wrap() {
	// Regression: wft_max at the u8 max must still abort — the counter must not wrap past
	// 255 back to 0 and tolerate WAITs forever.
	mut l := bound(Link{
		n_bs_us: 1000
		wft_max: 255
	}, default_message)
	mut buf := [default_message]u8{}
	assert l.send(&buf[0], 20)
	mut p := Pdu{}
	assert l.poll(0, mut p) // FF -> wait_fc

	mut wait := Pdu{}
	wait.data[0] = 0x31
	for _ in 0 .. 255 {
		l.on_frame(1, wait) // 255 WAITs tolerated
	}
	assert !l.send(&buf[0], 5) // still busy at the max
	l.on_frame(1, wait) // the 256th exceeds wft_max -> abort (no wrap)
	assert l.send(&buf[0], 5) // link freed
}

fn test_late_fc_after_deadline_aborts() {
	// A FC arriving after N_Bs has elapsed (but before poll runs the timeout) must not
	// revive the transfer — it aborts, matching the deadline poll() would enforce.
	mut l := bound(Link{
		n_bs_us: 1000
	}, default_message)
	mut buf := [default_message]u8{}
	assert l.send(&buf[0], 20)
	mut p := Pdu{}
	assert l.poll(0, mut p) // FF -> wait_fc (deadline 1000)

	mut wait := Pdu{}
	wait.data[0] = 0x31 // FC.WAIT, but arriving at/after the deadline
	l.on_frame(1000, wait) // now >= deadline -> abort, do not extend
	assert l.send(&buf[0], 5) // link is free, not resurrected
}

fn test_fc_wait_bounded_by_wftmax() {
	// An endless-WAIT peer must not re-wedge the link: after wft_max WAITs the tx aborts.
	mut l := bound(Link{
		n_bs_us: 1000
		wft_max: 3
	}, default_message)
	mut buf := [default_message]u8{}
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
	mut l := bound(Link{}, default_message)
	mut buf := [default_message]u8{}
	assert l.send(&buf[0], 10) // starts a tx (FF pending)
	assert !l.send(&buf[0], 5) // busy
	mut l2 := bound(Link{}, default_message)
	assert !l2.send(&buf[0], default_message + 1) // too long
}


fn test_n_cr_times_out_stalled_receive() {
	mut l := bound(Link{}, default_message)
	l.init_defaults()
	mut ff := Pdu{}
	ff.data[0] = 0x10
	ff.data[1] = 20 // 20-byte transfer: FF carries 6, needs CFs
	for i in 0 .. 6 {
		ff.data[2 + i] = u8(i)
	}
	l.on_frame(0, ff)
	assert l.rx == .receiving
	mut cts := Pdu{}
	assert l.poll(0, mut cts) // emit the CTS — N_Cr is armed from HERE (codex #218)
	// the sender dies; N_Cr (1 s default) elapses via tick — the reassembly is abandoned
	l.tick(1_000_001)
	assert l.rx == .idle
	// a LATE CF must not resurrect the dead transfer
	mut cf := Pdu{}
	cf.data[0] = 0x21
	l.on_frame(1_000_002, cf)
	assert l.rx == .idle
	mut dst := [default_message]u8{}
	assert l.take(&dst[0]) == 0
}

fn test_n_cr_refreshes_per_cf() {
	mut l := bound(Link{}, default_message)
	l.init_defaults()
	mut ff := Pdu{}
	ff.data[0] = 0x10
	ff.data[1] = 20
	for i in 0 .. 6 {
		ff.data[2 + i] = u8(i)
	}
	l.on_frame(0, ff)
	mut cts := Pdu{}
	assert l.poll(0, mut cts) // CTS out -> N_Cr armed from t=0
	// each CF lands just inside its own N_Cr window: the transfer completes even
	// though total elapsed time exceeds one window (per-gap bound, not per-transfer)
	mut cf1 := Pdu{}
	cf1.data[0] = 0x21
	for i in 0 .. 7 {
		cf1.data[1 + i] = u8(6 + i)
	}
	l.on_frame(900_000, cf1)
	assert l.rx == .receiving
	mut cf2 := Pdu{}
	cf2.data[0] = 0x22
	for i in 0 .. 7 {
		cf2.data[1 + i] = u8(13 + i)
	}
	l.on_frame(1_800_000, cf2)
	mut dst := [default_message]u8{}
	assert l.take(&dst[0]) == 20
	assert dst[6] == 6 && dst[19] == 19
}


fn test_n_cr_abort_clears_pending_fc() {
	mut l := bound(Link{}, default_message)
	l.init_defaults()
	l.n_ar_us = 0 // N_Cr alone: N_Ar, which ends this wait at 1 s, is its own test
	mut ff := Pdu{}
	ff.data[0] = 0x10
	ff.data[1] = 20
	for i in 0 .. 6 {
		ff.data[2 + i] = u8(i)
	}
	l.on_frame(0, ff) // fc_send pending, but the tx path is backpressured — CTS never
	// polled out, so N_Cr is NOT armed (rx_deadline stays 0). A very late tick then
	// finds a receive with no armed deadline (0): it must NOT abort a transfer whose
	// CTS is still legitimately pending, and if it does clear rx, the stale CTS must go
	// too. Here we assert the pending-CTS case survives the tick (deadline unarmed):
	l.tick(1_000_001)
	assert l.rx == .receiving // CTS never emitted -> N_Cr not started -> still waiting
	mut out := Pdu{}
	assert l.poll(1_000_002, mut out) // the pending CTS finally goes out (recovered)
	assert out.data[0] == 0x30
}


fn test_new_ff_after_prior_ncr_expiry() {
	mut l := bound(Link{}, default_message)
	l.init_defaults()
	// complete one small multi-frame transfer, leaving rx_deadline armed from its last CF
	mut ff := Pdu{}
	ff.data[0] = 0x10
	ff.data[1] = 8
	for i in 0 .. 6 {
		ff.data[2 + i] = u8(i)
	}
	l.on_frame(0, ff)
	mut cts := Pdu{}
	assert l.poll(0, mut cts)
	mut cf := Pdu{}
	cf.data[0] = 0x21
	cf.data[1] = 6
	cf.data[2] = 7
	l.on_frame(100_000, cf)
	mut dst := [default_message]u8{}
	assert l.take(&dst[0]) == 8
	// a NEW FF arrives long after that stale deadline; the generated bridge calls
	// tick() before its readiness-gated poll — the fresh receive must survive it and
	// still emit its CTS (codex #218)
	mut ff2 := Pdu{}
	ff2.data[0] = 0x10
	ff2.data[1] = 8
	l.on_frame(5_000_000, ff2)
	l.tick(5_000_001) // bridge ticks before poll — must NOT abort the just-armed receive
	assert l.rx == .receiving
	mut cts2 := Pdu{}
	assert l.poll(5_000_002, mut cts2)
	assert cts2.data[0] == 0x30
}

fn test_block_boundary_backpressured_cts_not_aborted() {
	mut l := bound(Link{}, default_message)
	l.init_defaults()
	l.n_ar_us = 0 // N_Cr alone: N_Ar, which ends this wait at 1 s, is its own test
	l.bs = 1 // one CF per block -> a CTS is due after every CF
	mut ff := Pdu{}
	ff.data[0] = 0x10
	ff.data[1] = 20
	for i in 0 .. 6 {
		ff.data[2 + i] = u8(i)
	}
	l.on_frame(0, ff)
	mut cts := Pdu{}
	assert l.poll(0, mut cts)
	// one CF fills the block; the receiver owes a CTS but the tx path is backpressured
	// (poll not called). tick() a full N_Cr later must NOT abort — the sender is
	// correctly waiting for that next CTS (codex #218)
	mut cf1 := Pdu{}
	cf1.data[0] = 0x21
	for i in 0 .. 7 {
		cf1.data[1 + i] = u8(6 + i)
	}
	l.on_frame(100_000, cf1)
	l.tick(1_200_000)
	assert l.rx == .receiving
	mut cts2 := Pdu{}
	assert l.poll(1_200_001, mut cts2) // the block CTS finally goes out; N_Cr arms now
	assert cts2.data[0] == 0x30
}

// abort_tx abandons a multi-frame send mid-flight: nothing more is polled out, and the link
// accepts a new message (an owner whose channel refused a frame must not keep sending the rest).
fn test_abort_tx_stops_a_transfer_in_flight() {
	mut l := bound(Link{}, default_message)
	l.init_defaults()
	mut msg := [20]u8{}
	assert l.send(&msg[0], 20)
	mut p := Pdu{}
	assert l.poll(0, mut p) // the First Frame
	assert l.busy()
	l.abort_tx()
	assert !l.busy()
	assert !l.poll(1, mut p), 'an aborted transfer kept sending'
	assert l.send(&msg[0], 3)
}

// a send the link gave up on is counted; one that completed is not — both leave it not busy
fn test_a_send_given_up_is_counted_apart_from_a_completed_one() {
	mut l := bound(Link{
		n_bs_us: 1000
	}, default_message)
	mut buf := [default_message]u8{}
	mut p := Pdu{}
	assert l.send(&buf[0], 5) // a single frame
	assert l.poll(0, mut p)
	assert !l.busy() && l.tx_aborts == 0 // completed
	assert l.send(&buf[0], 20)
	assert l.poll(0, mut p) // FF out, waiting for flow control
	l.tick(1000) // N_Bs ran out
	assert !l.busy() && l.tx_aborts == 1 // given up
}

// progress is what advanced a reception, never what the link ignored or rejected
fn test_only_frames_that_advance_a_reception_count_as_progress() {
	mut l := bound(Link{}, default_message)
	l.init_defaults()
	mut p := Pdu{}
	p.data[0] = 0x40 // a reserved PCI
	l.on_frame(0, p)
	p.data[0] = 0x30 // flow control nobody waits for
	l.on_frame(0, p)
	p.data[0] = 0x21 // a consecutive frame with no reception
	l.on_frame(0, p)
	assert l.progress == 0
	p.data[0] = 0x10 // first frame of 20 bytes
	p.data[1] = 20
	l.on_frame(0, p)
	assert l.progress == 1
	l.on_frame(0, p) // the same first frame again, its flow control still owed: a restart
	assert l.progress == 1 && l.rx == .receiving
	p.data[0] = 0x23 // out of sequence: aborts, no progress
	l.on_frame(0, p)
	assert l.progress == 1
	p.data[0] = 0x10 // a first frame after the abort starts a reception anew
	l.on_frame(0, p)
	assert l.progress == 2
	p.data[0] = 0x21 // a consecutive frame ahead of our flow control: taken, but no progress
	l.on_frame(0, p)
	assert l.progress == 2
}

// a flow control the transmission waits for is progress too — a WAIT within WFTmax as much as a
// CTS (N_Bs bounds each wait, WFTmax their number); the WAIT past WFTmax and an overflow give up,
// no progress
fn test_flow_control_a_transmission_waits_for_counts_as_progress() {
	mut l := bound(Link{}, default_message)
	l.init_defaults()
	l.wft_max = 2
	buf := []u8{len: 20, init: u8(index)}
	mut p := Pdu{}
	mut fc := Pdu{}
	assert l.send(&buf[0], 20)
	assert l.poll(0, mut p) // FF out, waiting for flow control
	fc.data[0] = 0x31 // WAIT
	l.on_frame(100, fc)
	l.on_frame(200, fc)
	assert l.progress == 2 && l.busy()
	l.on_frame(300, fc) // the third WAIT: past WFTmax
	assert l.progress == 2 && !l.busy() && l.tx_aborts == 1
	assert l.send(&buf[0], 20)
	assert l.poll(400, mut p)
	fc.data[0] = 0x32 // overflow
	l.on_frame(500, fc)
	assert l.progress == 2 && !l.busy() && l.tx_aborts == 2
	assert l.send(&buf[0], 20)
	assert l.poll(600, mut p)
	fc.data[0] = 0x30 // CTS
	l.on_frame(700, fc)
	assert l.progress == 3 && l.busy()
}

// a message of the maximum length crosses the sequence number's 15 -> 0 wrap intact (74 CFs)
fn test_a_max_length_message_wraps_the_sequence_number() {
	mut server := bound(Link{}, default_message)
	mut tester := bound(Link{}, default_message)
	mut req := [default_message]u8{}
	for i in 0 .. default_message {
		req[i] = u8(i * 7)
	}
	assert tester.send(&req[0], default_message)
	pump(mut tester, mut server, 1000)
	mut buf := [default_message]u8{}
	assert server.take(&buf[0]) == default_message
	for i in 0 .. default_message {
		assert buf[i] == u8(i * 7)
	}
}

// our flow control carries the block size and STmin we grant, and comes again after each block
fn test_flow_control_carries_our_block_size_and_stmin() {
	mut l := bound(Link{
		bs:    2
		stmin: 5
	}, default_message)
	l.init_defaults()
	mut p := Pdu{}
	l.on_frame(0, pdu([u8(0x10), 30, 0, 0, 0, 0, 0, 0]))
	assert l.poll(0, mut p)
	assert p.data[0] == 0x30 && p.data[1] == 2 && p.data[2] == 5
	l.on_frame(0, pdu([u8(0x21), 0, 0, 0, 0, 0, 0, 0]))
	assert !l.poll(0, mut p) // mid-block: no flow control owed
	l.on_frame(0, pdu([u8(0x22), 0, 0, 0, 0, 0, 0, 0]))
	assert l.poll(0, mut p) // block of 2 done: the next clear-to-send
	assert p.data[0] == 0x30 && p.data[1] == 2 && p.data[2] == 5
}

// a single frame claiming length 0 or above 7 is no message
fn test_a_single_frame_of_length_0_or_above_7_is_ignored() {
	mut l := bound(Link{}, default_message)
	mut buf := [default_message]u8{}
	l.on_frame(0, pdu([u8(0x00), 1, 2, 3, 4, 5, 6, 7]))
	assert l.take(&buf[0]) == 0
	l.on_frame(0, pdu([u8(0x08), 1, 2, 3, 4, 5, 6, 7]))
	assert l.take(&buf[0]) == 0
}

// starts a 30-byte transmission and grants it `bs` / `stmin` with a clear-to-send at `now`
fn granted(bs u8, stmin u8, now u64) Link {
	mut l := bound(Link{}, default_message)
	l.init_defaults()
	buf := [30]u8{}
	assert l.send(&buf[0], 30)
	mut p := Pdu{}
	assert l.poll(0, mut p) // FF
	l.on_frame(now, pdu([u8(0x30), bs, stmin, 0, 0, 0, 0, 0]))
	return l
}

// no more consecutive frames than the receiver's block size before its next flow control
fn test_transmission_honours_the_receivers_block_size() {
	mut l := granted(2, 0, 0)
	mut p := Pdu{}
	assert l.poll(0, mut p) && p.data[0] == 0x21
	assert l.poll(0, mut p) && p.data[0] == 0x22
	assert !l.poll(0, mut p) // waiting for the next clear-to-send
	l.on_frame(0, pdu([u8(0x30), 0, 0, 0, 0, 0, 0, 0]))
	assert l.poll(0, mut p) && p.data[0] == 0x23 // block size 0: the rest without waiting
	assert l.poll(0, mut p) && p.data[0] == 0x24
	assert !l.busy()
}

// consecutive frames are spaced by the receiver's STmin, in ms and in the 100..900 us range
fn test_transmission_honours_the_receivers_stmin() {
	mut l := granted(0, 5, 1000) // 5 ms
	mut p := Pdu{}
	assert l.poll(1000, mut p) && p.data[0] == 0x21
	assert !l.poll(5999, mut p)
	assert l.poll(6000, mut p) && p.data[0] == 0x22
	mut m := granted(0, 0xF3, 1000) // 300 us
	assert m.poll(1000, mut p)
	assert !m.poll(1299, mut p)
	assert m.poll(1300, mut p)
}

// a single frame arriving mid-reception ends it: the single frame is delivered, the partial not
fn test_a_single_frame_mid_reception_replaces_it() {
	mut l := bound(Link{}, default_message)
	l.init_defaults()
	mut buf := [default_message]u8{}
	l.on_frame(0, pdu([u8(0x10), 20, 1, 2, 3, 4, 5, 6]))
	l.on_frame(0, pdu([u8(0x02), 0x3E, 0x00, 0, 0, 0, 0, 0]))
	assert l.take(&buf[0]) == 2 && buf[0] == 0x3E
	mut p := Pdu{}
	assert !l.poll(0, mut p) // no clear-to-send for the reception it ended
	l.on_frame(0, pdu([u8(0x21), 7, 8, 9, 10, 11, 12, 13]))
	assert l.take(&buf[0]) == 0 // the old reception does not resume
}

// a first frame announcing more than default_message starts nothing: it is refused with FC.OVFLW,
// and ends a reception in progress
fn test_an_oversize_first_frame_is_refused_with_overflow() {
	mut l := bound(Link{}, default_message)
	l.init_defaults()
	mut buf := [default_message]u8{}
	mut p := Pdu{}
	l.on_frame(0, pdu([u8(0x10), 20, 1, 2, 3, 4, 5, 6]))
	total := default_message + 1
	l.on_frame(0, pdu([u8(0x10 | (total >> 8)), u8(total & 0xFF), 0, 0, 0, 0, 0, 0]))
	assert !l.idle() // a flow control is owed
	assert l.poll(0, mut p)
	assert p.data[0] == 0x32 && p.data[1] == 0 && p.data[2] == 0
	assert !l.poll(0, mut p) // once, and no CTS for the reception it ended
	assert l.idle()
	l.on_frame(0, pdu([u8(0x21), 7, 8, 9, 10, 11, 12, 13]))
	assert l.take(&buf[0]) == 0
}

// a refusal still owed when the sender restarts — with a valid first frame or a single frame — is
// never sent: it would fail the transfer that replaced the oversize one
fn test_an_owed_overflow_is_dropped_by_the_next_first_or_single_frame() {
	mut l := bound(Link{}, default_message)
	l.init_defaults()
	mut p := Pdu{}
	mut buf := [default_message]u8{}
	oversize := pdu([u8(0x10 | (600 >> 8)), u8(600 & 0xFF), 0, 0, 0, 0, 0, 0])
	l.on_frame(0, oversize)
	l.on_frame(0, pdu([u8(0x10), 20, 1, 2, 3, 4, 5, 6]))
	assert l.poll(0, mut p) && p.data[0] == 0x30 // the CTS for the valid one, no OVFLW
	assert !l.poll(0, mut p)
	l.on_frame(0, oversize)
	l.on_frame(0, pdu([u8(0x02), 0x3E, 0x00, 0, 0, 0, 0, 0]))
	assert l.take(&buf[0]) == 2
	assert !l.poll(0, mut p) && l.idle()
}

// an escape first frame (FF_DL 0: a 32-bit length follows, above 4095) is refused with FC.OVFLW
fn test_an_escape_first_frame_is_refused_with_overflow() {
	mut l := bound(Link{}, default_message)
	l.init_defaults()
	mut p := Pdu{}
	l.on_frame(0, pdu([u8(0x10), 0x00, 0x00, 0x00, 0x13, 0x88, 1, 2]))
	assert l.poll(0, mut p) && p.data[0] == 0x32
}

// a reserved STmin is read as 0x7F (127 ms), never as 0 (back-to-back)
fn test_a_reserved_stmin_is_read_as_127_ms() {
	for b in [u8(0x80), 0xF0, 0xFA, 0xFF] {
		mut l := granted(0, b, 0)
		mut p := Pdu{}
		assert l.poll(0, mut p)
		assert !l.poll(126_999, mut p), 'STmin 0x${b:02X}'
		assert l.poll(127_000, mut p), 'STmin 0x${b:02X}'
	}
}

// a flow status the standard does not define (3..15) ends the transmission at once, counted
fn test_an_undefined_flow_status_aborts_the_transmission() {
	for fs in 3 .. 16 {
		mut l := bound(Link{}, default_message)
		l.init_defaults()
		buf := [20]u8{}
		mut p := Pdu{}
		assert l.send(&buf[0], 20)
		assert l.poll(0, mut p) // FF
		l.on_frame(100, pdu([u8(0x30 | fs), 0, 0, 0, 0, 0, 0, 0]))
		assert !l.busy() && l.tx_aborts == 1, 'FS ${fs}'
	}
}

// @verifies REQ-CAN-TP-013 REQ-CAN-TP-028
// the length each frame type needs before its bytes are read: on_frame reads nothing of a frame too
// short for its PCI, and keeps the reception a consecutive frame of the wrong length arrives in
fn test_truncated_frames_by_type() {
	mut buf := [default_message]u8{}
	mut p := Pdu{}
	mut l := bound(Link{}, default_message)
	l.init_defaults()
	// a single frame of 3 needs 4 bytes
	l.on_frame(0, pdu([u8(0x03), 0x22, 0xF1]))
	assert !l.has_request()
	l.on_frame(0, pdu([u8(0x03), 0x22, 0xF1, 0x90]))
	assert l.take(&buf[0]) == 3
	// an escape single frame needs 2 + its length: 11 bytes do not fit a 12-byte frame, 10 do
	mut esc := []u8{len: 12}
	esc[1] = 11
	l.on_frame(0, pdu(esc))
	assert !l.has_request()
	esc[1] = 10
	l.on_frame(0, pdu(esc))
	assert l.take(&buf[0]) == 10
	// a first frame needs 8: seven bytes start nothing and owe nothing
	l.on_frame(0, pdu([u8(0x10), 22, 1, 2, 3, 4, 5]))
	assert l.idle()
	l.on_frame(0, pdu([u8(0x10), 22, 1, 2, 3, 4, 5, 6]))
	assert l.rx == .receiving
	assert l.poll(0, mut p) && p.data[0] == 0x30
	// 16 bytes to come: a consecutive frame shorter than the first frame's 8 is ignored, the
	// reception kept — and so is one longer than it
	l.on_frame(0, pdu([u8(0x21), 7, 8, 9, 10, 11, 12]))
	assert l.rx == .receiving && l.rx_pos == 6
	mut long := []u8{len: 12, init: u8(0x40 + index)}
	long[0] = 0x21
	l.on_frame(0, pdu(long))
	assert l.rx == .receiving && l.rx_pos == 6
	l.on_frame(0, pdu([u8(0x21), 7, 8, 9, 10, 11, 12, 13]))
	l.on_frame(0, pdu([u8(0x22), 14, 15, 16, 17, 18, 19, 20]))
	// the last 2 bytes need 3
	l.on_frame(0, pdu([u8(0x23), 21]))
	assert !l.has_request() && l.rx == .receiving
	l.on_frame(0, pdu([u8(0x23), 21, 22]))
	assert l.take(&buf[0]) == 22
	for i in 0 .. 22 {
		assert buf[i] == u8(i + 1)
	}
	// a flow control needs FS, BS and STmin
	assert l.send(&buf[0], 20)
	assert l.poll(0, mut p) && p.data[0] == 0x10
	l.on_frame(0, pdu([u8(0x30), 0]))
	assert l.tx == .wait_fc
	l.on_frame(0, pdu([u8(0x30), 0, 0]))
	assert l.tx == .send_cf
}

// a first frame announcing `total` bytes
fn first_frame(total int) Pdu {
	return pdu([u8(0x10 | (total >> 8)), u8(total & 0xFF), 1, 2, 3, 4, 5, 6])
}

// @verifies REQ-CAN-TP-014
// the maximum is the one the owner gives the link, at the floor, the default and the limit: a
// message of that length goes both ways intact (the sequence number wrapping on the long ones),
// one byte more is refused to send, and a first frame announcing one byte more starts nothing
fn test_the_maximum_is_the_capacity_the_owner_binds() {
	for cap in [min_message, default_message, message_limit] {
		mut a := bound(Link{}, cap)
		mut b := bound(Link{}, cap)
		a.init_defaults()
		b.init_defaults()
		msg := []u8{len: cap, init: u8(index * 13 + 1)}
		assert a.send(&msg[0], cap), 'cap ${cap}'
		pump(mut a, mut b, 1000)
		got := []u8{len: cap}
		assert b.take(&got[0]) == cap, 'cap ${cap}'
		assert got == msg, 'cap ${cap}'
		big := []u8{len: cap + 1}
		assert !a.send(&big[0], cap + 1), 'cap ${cap}'
		mut p := Pdu{}
		if cap < message_limit {
			b.on_frame(0, first_frame(cap + 1))
			assert b.poll(0, mut p) && p.data[0] == 0x32, 'cap ${cap}'
			assert b.rx == .idle && b.take(&got[0]) == 0
		}
		b.on_frame(0, first_frame(cap))
		assert b.poll(0, mut p) && p.data[0] == 0x30, 'cap ${cap}' // the maximum itself is taken
	}
}

// @verifies REQ-CAN-TP-014 REQ-CAN-TP-015
// at the limit only the escape first frame is above the capacity: FF_DL 4095 starts a reception,
// FF_DL 0 draws FC.OVFLW
fn test_at_the_limit_only_the_escape_first_frame_overflows() {
	mut l := bound(Link{}, message_limit)
	l.init_defaults()
	mut p := Pdu{}
	l.on_frame(0, first_frame(4095))
	assert l.rx == .receiving
	assert l.poll(0, mut p) && p.data[0] == 0x30
	l.on_frame(0, first_frame(0))
	assert l.poll(0, mut p) && p.data[0] == 0x32
	assert l.rx == .idle
}

// a single frame longer than a capacity below 7 is not taken
fn test_a_single_frame_longer_than_the_capacity_is_ignored() {
	mut l := bound(Link{}, 3)
	mut buf := [8]u8{}
	l.on_frame(0, pdu([u8(0x04), 1, 2, 3, 4, 0, 0, 0]))
	assert l.take(&buf[0]) == 0
	l.on_frame(0, pdu([u8(0x03), 1, 2, 3, 0, 0, 0, 0]))
	assert l.take(&buf[0]) == 3
}

// a link nobody bound fails closed: nothing is sent, every first frame is refused, nothing written
fn test_an_unbound_link_fails_closed() {
	mut l := Link{}
	l.init_defaults()
	buf := [20]u8{}
	assert !l.send(&buf[0], 1)
	l.on_frame(0, pdu([u8(0x02), 0x3E, 0, 0, 0, 0, 0, 0]))
	assert !l.has_request()
	l.on_frame(0, first_frame(20))
	mut p := Pdu{}
	assert l.poll(0, mut p) && p.data[0] == 0x32
	assert l.rx == .idle
}

// a capacity above the limit is clamped to it, a nil buffer is capacity 0, and the transmit
// buffer is not exchanged under a transmission in flight
fn test_bind_clamps_and_is_refused_while_sending() {
	mut l := Link{}
	big := []u8{len: message_limit + 100}
	l.bind_rx(&big[0], message_limit + 100)
	assert l.bind_tx(&big[0], message_limit + 100)
	assert l.rx_cap == message_limit && l.tx_cap == message_limit
	assert l.bind_tx(unsafe { nil }, 100) && l.tx_cap == 0
	l.bind_rx(unsafe { nil }, 100)
	assert l.rx_cap == 0
	assert l.bind_tx(&big[0], 30)
	assert l.send(&big[0], 20)
	other := []u8{len: 30}
	assert !l.bind_tx(&other[0], 30) && l.tx_buf == &big[0]
}

// the owner may send from the link's own transmit buffer and take into its own receive buffer:
// the message is where it already is
fn test_send_and_take_on_the_links_own_buffers() {
	mut a := bound(Link{}, 64)
	mut b := bound(Link{}, 64)
	a.init_defaults()
	b.init_defaults()
	for i in 0 .. 40 {
		unsafe {
			a.tx_buf[i] = u8(i + 3)
		}
	}
	assert a.send(a.tx_buf, 40)
	pump(mut a, mut b, 1000)
	assert b.take(b.rx_buf) == 40
	for i in 0 .. 40 {
		assert unsafe { b.rx_buf[i] } == u8(i + 3)
	}
}

// @verifies REQ-CAN-TP-024
// a transmit-only link's flow-control id takes flow control and nothing else: a first frame, a
// single frame, a consecutive frame and a truncated flow control are dropped — no reception starts
// and no flow control is owed — while the clear-to-send the transmission waits for goes in
fn test_a_transmit_only_link_takes_only_flow_control() {
	mut l := bound(Link{}, default_message)
	l.init_defaults()
	msg := []u8{len: 40, init: u8(index)}
	assert l.send(&msg[0], msg.len)
	mut p := Pdu{}
	assert l.poll(0, mut p) && p.data[0] >> 4 == 1 // the first frame; flow control awaited
	for f in [[u8(0x10), 20, 1, 2, 3, 4, 5, 6], [u8(0x03), 0x22, 0xF1, 0x90],
		[u8(0x21), 1, 2, 3, 4, 5, 6, 7], [u8(0x30), 0]] {
		assert !l.on_flow_control(1, &f[0], f.len), f.str()
	}
	assert l.rx == .idle && !l.fc_send && !l.fc_ovflw && !l.has_request()
	assert !l.poll(1, mut p), 'nothing goes out on a frame that is not flow control'
	cts := [u8(0x30), 0, 0, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA] // CAN-FD padded
	assert l.on_flow_control(2, &cts[0], cts.len)
	assert l.poll(2, mut p) && p.data[0] == 0x21
}

// ---- CAN-FD frame formats (TX_DL above 8, any RX_DL) ------------------------------------------
// The byte vectors are blobly_net's blobly/isotp/fd_test.v's, so both repos pin the same frames —
// with the fill byte 0x00 where those tests pad with 0xAA or 0xCC (this link's fill is fixed), and
// a frame a CAN-FD bus carries at its padded length where they hand the bus a shorter one.

// bytes_from: n bytes counting up from `first`
fn bytes_from(n int, first u8) []u8 {
	return []u8{len: n, init: u8(first + u8(index))}
}

// cat: the bytes of every part, in order
fn cat(parts [][]u8) []u8 {
	mut out := []u8{}
	for x in parts {
		out << x
	}
	return out
}

// polled: the next frame the link sends, as the wire carries it
fn polled(mut l Link, now u64) []u8 {
	mut p := Pdu{}
	assert l.poll(now, mut p)
	return p.data[..p.len].clone()
}

// a sender at `tx_dl`
fn sender(tx_dl u8) Link {
	mut l := bound(Link{
		tx_dl: tx_dl
	}, default_message)
	l.init_defaults()
	return l
}

// @verifies REQ-CAN-TP-027
// a single frame at TX_DL 64: up to 7 bytes the classic form in 8, past it the escape (0x00, the
// length) padded to the next CAN-FD length, up to TX_DL - 2; past that a first frame of TX_DL
fn test_single_frames_with_a_long_tx_dl() {
	mut l := sender(64)
	m7 := bytes_from(7, 1)
	assert l.send(&m7[0], m7.len)
	assert polled(mut l, 0) == [u8(0x07), 1, 2, 3, 4, 5, 6, 7]
	m20 := bytes_from(20, 1)
	assert l.send(&m20[0], m20.len)
	assert polled(mut l, 0) == cat([[u8(0x00), 20], m20, [u8(0), 0]]) // 22 bytes padded to 24
	m62 := bytes_from(62, 0)
	assert l.send(&m62[0], m62.len)
	assert polled(mut l, 0) == cat([[u8(0x00), 62], m62]) // 64 bytes
	m63 := bytes_from(63, 0)
	assert l.send(&m63[0], m63.len)
	assert polled(mut l, 0) == cat([[u8(0x10), 63], m63[..62]]) // a first frame of 64
	// at TX_DL 12: ten bytes the escape in 12, eleven a first frame of 12
	mut t := sender(12)
	m10 := bytes_from(10, 0)
	assert t.send(&m10[0], m10.len)
	assert polled(mut t, 0) == cat([[u8(0x00), 10], m10])
	m11 := bytes_from(11, 0)
	assert t.send(&m11[0], m11.len)
	assert polled(mut t, 0) == cat([[u8(0x10), 11], m11[..10]])
}

// @verifies REQ-CAN-TP-027
// a first frame of TX_DL bytes, consecutive frames of TX_DL - 1, the last one only what is left,
// padded up to the next CAN-FD length (or 8); our flow control is 8 bytes whatever the TX_DL
fn test_first_and_consecutive_frames_with_a_long_tx_dl() {
	mut l := sender(16)
	msg := bytes_from(41, 0) // 14 in the first frame, 15, then 12 in a 13-byte frame padded to 16
	assert l.send(&msg[0], msg.len)
	assert polled(mut l, 0) == cat([[u8(0x10), 41], msg[..14]])
	l.on_frame(0, pdu([u8(0x30), 0, 0]))
	assert polled(mut l, 0) == cat([[u8(0x21)], msg[14..29]])
	assert polled(mut l, 0) == cat([[u8(0x22)], msg[29..], [u8(0), 0, 0]])
	assert !l.busy()
	// at 64, 65 bytes: a first frame of 62, then the last 3 in a frame of 8
	mut m := sender(64)
	m65 := bytes_from(65, 0)
	assert m.send(&m65[0], m65.len)
	assert polled(mut m, 0).len == 64
	m.on_frame(0, pdu([u8(0x30), 0, 0]))
	assert polled(mut m, 0) == [u8(0x21), 62, 63, 64, 0, 0, 0, 0]
	// the flow control this link owes as a receiver: 8 bytes, CTS and OVFLW alike
	m.on_frame(0, pdu([u8(0x10), 20, 1, 2, 3, 4, 5, 6]))
	assert polled(mut m, 0) == [u8(0x30), 0, 0, 0, 0, 0, 0, 0]
	m.on_frame(0, pdu([u8(0x10), 0, 0, 1, 0, 0, 1, 2]))
	assert polled(mut m, 0) == [u8(0x32), 0, 0, 0, 0, 0, 0, 0]
}

// @verifies REQ-CAN-TP-027
// a TX_DL that is no length ISO-TP transmits with reads as 8; the length a message goes out at is
// the one send() found, whatever the field says meanwhile
fn test_tx_dl_is_taken_once_per_message_and_an_invalid_one_reads_as_8() {
	for dl in [u8(0), 7, 13, 65, 255] {
		mut l := sender(dl)
		msg := bytes_from(20, 0)
		assert l.send(&msg[0], msg.len)
		assert polled(mut l, 0) == cat([[u8(0x10), 20], msg[..6]]), 'tx_dl ${dl}'
	}
	mut l := sender(64)
	msg := bytes_from(200, 0)
	assert l.send(&msg[0], msg.len)
	assert polled(mut l, 0).len == 64
	l.tx_dl = 8 // a later change: the message in flight keeps its 64-byte frames
	l.on_frame(0, pdu([u8(0x30), 0, 0]))
	assert polled(mut l, 0) == cat([[u8(0x21)], msg[62..125]])
	assert polled(mut l, 0) == cat([[u8(0x22)], msg[125..188]])
	assert polled(mut l, 0) == cat([[u8(0x23)], msg[188..], [u8(0), 0, 0]])
	assert l.send(&msg[0], 20) // the next message takes the new value
	assert polled(mut l, 0).len == 8
}

// @verifies REQ-CAN-TP-001 REQ-CAN-TP-027 REQ-CAN-TP-028
// a sender at every TX_DL and a receiver with no setting: the message arrives whole, at the floor,
// the default and the limit
fn test_every_tx_dl_round_trips_with_no_setting_at_the_receiver() {
	for dl in [8, 12, 16, 20, 24, 32, 48, 64] {
		for n in [1, 7, 8, sf_max(dl), sf_max(dl) + 1, 520, message_limit] {
			mut a := bound(Link{
				tx_dl: u8(dl)
			}, message_limit)
			mut b := bound(Link{}, message_limit)
			a.init_defaults()
			b.init_defaults()
			msg := []u8{len: n, init: u8(index * 7 + dl)}
			assert a.send(&msg[0], n)
			pump(mut a, mut b, 1000)
			got := []u8{len: n}
			assert b.take(&got[0]) == n, 'tx_dl ${dl}, ${n} bytes'
			assert got == msg, 'tx_dl ${dl}, ${n} bytes'
		}
	}
}

// @verifies REQ-CAN-TP-028
// received with no setting: a single frame behind the escape, and a first frame of 64 bytes with
// consecutive frames as long, the last one shorter
fn test_fd_frames_are_received_with_no_setting() {
	mut l := bound(Link{}, default_message)
	l.init_defaults()
	mut buf := [default_message]u8{}
	l.on_frame(0, pdu(cat([[u8(0x00), 20], bytes_from(20, 3), [u8(0), 0]]))) // padded to 24
	assert l.take(&buf[0]) == 20
	assert buf[..20] == bytes_from(20, 3)
	msg := bytes_from(200, 0) // 62, 63, 63, then 12 in a 13-byte frame padded to 16
	l.on_frame(0, pdu(cat([[u8(0x10), 200], msg[..62]])))
	assert polled(mut l, 0) == [u8(0x30), 0, 0, 0, 0, 0, 0, 0]
	l.on_frame(0, pdu(cat([[u8(0x21)], msg[62..125]])))
	l.on_frame(0, pdu(cat([[u8(0x22)], msg[125..188]])))
	assert !l.has_request()
	l.on_frame(0, pdu(cat([[u8(0x23)], msg[188..], [u8(0), 0, 0]])))
	assert l.take(&buf[0]) == 200
	assert buf[..200] == msg
}

// @verifies REQ-CAN-TP-028
// a frame no CAN-FD sender produces is ignored, nothing delivered and no flow control owed: a
// single frame past 8 bytes without the escape, a classic length above 7, an escape claiming 0 or
// more than its frame holds, a first frame whose length fits a single frame of its size (1..7 in 8
// bytes, up to 10 in 12, 62 in 64), and frames of a length no CAN-FD frame has. Each single frame
// breaks one rule only: the classic ones in 12 bytes carry a valid escape length in their second
// byte (8, 1), so only the escape byte (0x00) refuses them
fn test_malformed_fd_frames_are_ignored() {
	mut esc0 := []u8{len: 12}
	mut esc11 := []u8{len: 12}
	esc11[1] = 11
	mut esc13 := []u8{len: 13} // a 13-byte frame: no CAN-FD length
	esc13[1] = 5
	classic2 := cat([[u8(0x02), 0x08, 0x3E], []u8{len: 9}]) // SF_DL 2 padded to 12; byte 1 = 8
	classic9 := cat([[u8(0x09)], bytes_from(11, 1)]) // SF_DL 9 in 12; byte 1 = 1
	for f in [classic2, classic9, [u8(0x08), 1, 2, 3, 4, 5, 6, 7], esc0, esc11, esc13,
		[u8(0x10), 1, 1, 2, 3, 4, 5, 6], [u8(0x10), 5, 1, 2, 3, 4, 5, 6],
		[u8(0x10), 7, 1, 2, 3, 4, 5, 6], cat([[u8(0x10), 10], bytes_from(10, 0)]),
		cat([[u8(0x10), 62], bytes_from(62, 0)]), cat([[u8(0x10), 100], bytes_from(8, 0)])] {
		mut l := bound(Link{}, default_message)
		l.init_defaults()
		l.on_frame(0, pdu(f))
		assert l.idle(), '${f.len} bytes, ${f[0]:02X} ${f[1]:02X}'
		assert l.progress == 0
	}
	// one byte more than a single frame of the size carries: a reception, its CTS owed
	for f in [[u8(0x10), 8, 1, 2, 3, 4, 5, 6], cat([[u8(0x10), 11], bytes_from(10, 0)]),
		cat([[u8(0x10), 63], bytes_from(62, 0)])] {
		mut l := bound(Link{}, default_message)
		l.init_defaults()
		l.on_frame(0, pdu(f))
		assert l.rx == .receiving && l.fc_send, '${f.len} bytes, FF_DL ${f[1]}'
	}
}

// @verifies REQ-CAN-TP-028
// a consecutive frame or a flow control of a length no CAN-FD frame has is ignored, though it holds
// all its PCI and the reception need: the last consecutive frame of a reception at RX_DL 16 sent in
// 13 bytes (its padding off, which a CAN-FD frame longer than 8 cannot be), a flow control in 10 —
// on the physical id and on a stream's flow-control id alike; the same frames at a CAN-FD length go in
fn test_consecutive_and_flow_control_frames_of_no_fd_length_are_ignored() {
	mut l := bound(Link{}, default_message)
	l.init_defaults()
	msg := bytes_from(41, 0) // RX_DL 16: 14 in the first frame, 15, then the last 12
	l.on_frame(0, pdu(cat([[u8(0x10), 41], msg[..14]])))
	assert polled(mut l, 0)[0] == 0x30
	l.on_frame(0, pdu(cat([[u8(0x21)], msg[14..29]])))
	before := l.progress
	l.on_frame(0, pdu(cat([[u8(0x22)], msg[29..]]))) // 13 bytes
	assert l.rx == .receiving && !l.has_request() && l.progress == before
	l.on_frame(0, pdu(cat([[u8(0x22)], msg[29..], [u8(0), 0, 0]]))) // padded to 16
	mut buf := [default_message]u8{}
	assert l.take(&buf[0]) == 41 && buf[..41] == msg
	// a flow control of 10 bytes, then of 12
	mut s := sender(8)
	m := bytes_from(20, 0)
	assert s.send(&m[0], m.len)
	assert polled(mut s, 0)[0] == 0x10
	fc10 := [u8(0x30), 0, 0, 0, 0, 0, 0, 0, 0, 0]
	s.on_frame(0, pdu(fc10))
	assert s.tx == .wait_fc && s.progress == 0
	assert !s.on_flow_control(0, &fc10[0], fc10.len)
	assert s.tx == .wait_fc && s.progress == 0
	fc12 := []u8{len: 12, init: if index == 0 { u8(0x30) } else { u8(0) }}
	assert s.on_flow_control(0, &fc12[0], fc12.len)
	assert s.tx == .send_cf
}

// @verifies REQ-CAN-TP-028
// a consecutive frame longer than its first frame, or shorter with more to come, is ignored and the
// reception kept: the right one still advances it, and only that is progress
fn test_a_consecutive_frame_of_the_wrong_length_is_ignored() {
	mut l := bound(Link{}, default_message)
	l.init_defaults()
	mut buf := [default_message]u8{}
	msg := bytes_from(100, 0)
	l.on_frame(0, pdu(cat([[u8(0x10), 100], msg[..14]]))) // RX_DL 16
	assert polled(mut l, 0)[0] == 0x30
	before := l.progress
	l.on_frame(0, pdu([]u8{len: 64, init: u8(0x21)}))
	assert l.rx == .receiving && l.rx_pos == 14 && l.progress == before
	l.on_frame(0, pdu(cat([[u8(0x21)], msg[14..29]])))
	assert l.rx_pos == 29 && l.progress == before + 1
	// at RX_DL 64, a 16-byte consecutive frame with more to come
	mut m := bound(Link{}, default_message)
	m.init_defaults()
	big := bytes_from(200, 0)
	m.on_frame(0, pdu(cat([[u8(0x10), 200], big[..62]])))
	assert polled(mut m, 0)[0] == 0x30
	m.on_frame(0, pdu([]u8{len: 16, init: u8(0x21)}))
	assert m.rx == .receiving && m.rx_pos == 62 && !m.has_request()
	m.on_frame(0, pdu(cat([[u8(0x21)], big[62..125]])))
	m.on_frame(0, pdu(cat([[u8(0x22)], big[125..188]])))
	m.on_frame(0, pdu(cat([[u8(0x23)], big[188..], [u8(0), 0, 0]]))) // 13 bytes padded to 16
	assert m.take(&buf[0]) == 200 && buf[..200] == big
}

// @verifies REQ-CAN-TP-015 REQ-CAN-TP-028
// first frames refused with FC.OVFLW, 8 bytes: blobly_net's escape first frame stating 65536 (both
// repos answer it so), a first frame of 64 bytes past the capacity, and — blobly_emb's own rule
// (REQ-CAN-TP-015), where ISO 15765-2:2016 and blobly_net ignore it — an escape first frame stating
// 4095, which the 12-bit form states. overflows() answers as on_frame does for every first frame
// here and above.
fn test_fd_first_frames_refused_with_overflow() {
	small := bound(Link{}, 100)
	for f in [[u8(0x10), 0, 0, 1, 0, 0, 1, 2], cat([[u8(0x10), 0, 0, 0, 0x0F, 0xFF], bytes_from(58, 0)]),
		cat([[u8(0x10), 101], bytes_from(62, 0)])] {
		mut l := small
		l.init_defaults()
		q := pdu(f)
		assert l.overflows(&q)
		l.on_frame(0, q)
		assert polled(mut l, 0) == [u8(0x32), 0, 0, 0, 0, 0, 0, 0], '${f.len} bytes'
		assert l.idle()
	}
	for f in [cat([[u8(0x10), 100], bytes_from(62, 0)]), cat([[u8(0x10), 62], bytes_from(62, 0)]),
		cat([[u8(0x10), 100], bytes_from(8, 0)]), [u8(0x10), 20, 1, 2, 3, 4, 5]] {
		q := pdu(f)
		assert !small.overflows(&q), '${f.len} bytes'
	}
	// an escape single frame longer than the capacity is not taken — in a frame of a CAN-FD length,
	// so the capacity is what refuses it — and the reception it arrives in is kept: a frame the link
	// ignores is no new message (REQ-CAN-TP-012, -028)
	mut l := bound(Link{}, 10)
	l.init_defaults()
	l.on_frame(0, pdu(cat([[u8(0x00), 11], bytes_from(11, 0), [u8(0), 0, 0]]))) // 13 bytes padded to 16
	assert !l.has_request() && l.idle() && l.progress == 0
	l.on_frame(0, pdu(cat([[u8(0x00), 10], bytes_from(10, 0)]))) // 12 bytes
	assert l.has_request() && l.ready_len == 10
	mut buf := [10]u8{}
	assert l.take(&buf[0]) == 10
	l.on_frame(0, pdu([u8(0x10), 9, 1, 2, 3, 4, 5, 6]))
	assert l.rx == .receiving
	l.on_frame(0, pdu(cat([[u8(0x00), 11], bytes_from(11, 0), [u8(0), 0, 0]])))
	assert l.rx == .receiving && l.fc_send && !l.has_request()
}

// ---- N_Ar ---------------------------------------------------------------------------------------

// a link that has taken a first frame of 20 bytes at `now`, its CTS owed
fn owing_cts(now u64) Link {
	mut l := bound(Link{}, default_message)
	l.init_defaults()
	l.on_frame(now, pdu([u8(0x10), 20, 1, 2, 3, 4, 5, 6]))
	return l
}

// @verifies REQ-CAN-TP-029
// a flow control the controller never takes abandons its reception N_Ar after it became owed: the
// link goes idle, owes nothing and counts it — a CTS for a first frame, an OVFLW, and a block's CTS
fn test_a_flow_control_that_cannot_leave_abandons_the_reception_after_n_ar() {
	mut p := Pdu{}
	mut l := owing_cts(0)
	l.tick(999_999)
	assert !l.idle() && l.rx == .receiving
	l.tick(1_000_000)
	assert l.idle() && l.rx_aborts == 1
	assert !l.poll(1_000_000, mut p)
	// an OVFLW owed
	mut o := bound(Link{}, default_message)
	o.init_defaults()
	o.on_frame(0, first_frame(default_message + 1))
	o.tick(999_999)
	assert !o.idle()
	o.tick(1_000_000)
	assert o.idle() && o.rx_aborts == 1 && !o.poll(1_000_000, mut p)
	// the CTS a block of 2 owes, from the consecutive frame that ended the block
	mut b := bound(Link{
		bs: 2
	}, default_message)
	b.init_defaults()
	b.on_frame(0, pdu([u8(0x10), 30, 1, 2, 3, 4, 5, 6]))
	assert b.poll(0, mut p) && p.data[0] == 0x30
	b.on_frame(10_000, pdu([u8(0x21), 7, 8, 9, 10, 11, 12, 13]))
	b.on_frame(20_000, pdu([u8(0x22), 14, 15, 16, 17, 18, 19, 20]))
	b.tick(1_019_999)
	assert b.rx == .receiving
	b.tick(1_020_000)
	assert b.idle() && b.rx_aborts == 1 && !b.poll(1_020_000, mut p)
}

// @verifies REQ-CAN-TP-029
// N_Ar runs from the first flow control owed: a repeated first frame while the CTS is still owed,
// or an oversize one replacing it, does not restart it — nor, while an OVFLW is owed, a repeated
// oversize first frame or a valid one replacing the refusal; a CTS handed over in time ends it (N_Cr
// then bounds the reception)
fn test_n_ar_is_not_restarted_and_ends_when_the_flow_control_leaves() {
	mut p := Pdu{}
	mut l := owing_cts(0)
	l.on_frame(600_000, pdu([u8(0x10), 20, 1, 2, 3, 4, 5, 6]))
	l.tick(999_999)
	assert l.rx == .receiving
	l.tick(1_000_000)
	assert l.idle() && l.rx_aborts == 1
	mut o := owing_cts(0)
	o.on_frame(600_000, first_frame(default_message + 1))
	o.tick(1_000_000)
	assert o.idle() && o.rx_aborts == 1 && !o.poll(1_000_000, mut p)
	// an OVFLW owed from 0: the first frame after it, oversize again or valid, keeps that deadline
	for second in [first_frame(default_message + 1), pdu([u8(0x10), 20, 1, 2, 3, 4, 5, 6])] {
		mut v := bound(Link{}, default_message)
		v.init_defaults()
		v.on_frame(0, first_frame(default_message + 1))
		v.on_frame(600_000, second)
		v.tick(999_999)
		assert !v.idle(), 'FF_DL ${second.data[1]}'
		v.tick(1_000_000)
		assert v.idle() && v.rx_aborts == 1 && !v.poll(1_000_000, mut p), 'FF_DL ${second.data[1]}'
	}
	// the CTS leaves at 500 ms: no N_Ar, and N_Cr runs from there
	mut c := owing_cts(0)
	assert c.poll(500_000, mut p) && p.data[0] == 0x30
	c.tick(1_000_000)
	assert c.rx == .receiving && c.rx_aborts == 0
	c.tick(1_500_000)
	assert c.idle() && c.rx_aborts == 1
}

// @verifies REQ-CAN-TP-008 REQ-CAN-TP-029
// N_Cr counts in rx_aborts, by the timer and by a late consecutive frame alike; the owner's own
// abort_rx does not; a zeroed link has no N_Ar until init_defaults gives it 1 s; and a sequence
// error owes no stale CTS
fn test_receptions_given_up_are_counted() {
	mut p := Pdu{}
	mut l := owing_cts(0)
	assert l.poll(0, mut p)
	l.on_frame(1_000_000, pdu([u8(0x21), 7, 8, 9, 10, 11, 12, 13])) // past N_Cr
	assert l.idle() && l.rx_aborts == 1
	mut a := owing_cts(0)
	a.abort_rx()
	assert a.idle() && a.rx_aborts == 0
	mut z := bound(Link{}, default_message)
	z.n_bs_us = 1_000_000
	z.on_frame(0, pdu([u8(0x10), 20, 1, 2, 3, 4, 5, 6]))
	z.tick(10_000_000)
	assert z.rx == .receiving && z.rx_aborts == 0 // n_ar_us 0: disabled
	z.init_defaults()
	assert z.n_ar_us == 1_000_000
	// a block's CTS owed, then a consecutive frame out of sequence: the reception ends, nothing owed
	mut s := owing_cts(0)
	s.bs = 1
	assert s.poll(0, mut p)
	s.on_frame(1000, pdu([u8(0x21), 7, 8, 9, 10, 11, 12, 13]))
	assert s.fc_send
	s.on_frame(2000, pdu([u8(0x23), 0, 0, 0, 0, 0, 0, 0]))
	assert s.idle() && !s.poll(2000, mut p)
}
