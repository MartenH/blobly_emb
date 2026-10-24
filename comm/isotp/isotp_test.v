module isotp

// @verifies REQ-TP-001 REQ-TP-002 REQ-TP-003 REQ-TP-004 REQ-TP-005 REQ-TP-007 REQ-TP-008 REQ-TP-009
// @verifies REQ-TP-011 REQ-TP-012 REQ-TP-013 REQ-TP-014 REQ-TP-016 REQ-TP-017 REQ-TP-018
// (segmentation/reassembly: single/first/consecutive frames, sequence wrap, blocksize, STmin, both
//  directions; flow control incl. WAIT bounds, N_Bs/N_Cr timeouts, sequence errors, unexpected and
//  truncated frames, the length bound, busy refusal, abort counting and abort_tx.)

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

// A Consecutive Frame with the wrong sequence number (a dropped/reordered frame) aborts the
// reassembly instead of misassembling it — nothing becomes ready — and a fresh First Frame on the
// same link resyncs cleanly. (The host-side receiver in blobly_net enforces the same invariant;
// this is the target end of that contract.)
fn test_cf_sequence_mismatch_aborts_then_resyncs() {
	mut l := Link{}
	mut buf := [max_payload]u8{}

	// First Frame (total 14, first 6 bytes) -> receiving, expecting CF SN 1.
	l.on_frame(0, Pdu{
		data: [u8(0x10), 14, 1, 2, 3, 4, 5, 6]!
	})
	// A CF with SN 2 (expected 1) -> sequence error -> abort.
	l.on_frame(0, Pdu{
		data: [u8(0x22), 7, 8, 9, 10, 11, 12, 13]!
	})
	assert l.take(&buf[0]) == 0 // aborted, not misassembled — nothing ready

	// The same link resyncs on a fresh First Frame (total 9) + a correctly-numbered CF (SN 1).
	l.on_frame(0, Pdu{
		data: [u8(0x10), 9, 0xA0, 0xB0, 0xC0, 0xD0, 0xE0, 0xF0]!
	})
	l.on_frame(0, Pdu{
		data: [u8(0x21), 0x11, 0x22, 0x33, 0, 0, 0, 0]!
	})
	got := l.take(&buf[0])
	assert got == 9
	assert buf[0] == 0xA0 && buf[5] == 0xF0 && buf[6] == 0x11 && buf[8] == 0x33
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

fn test_tick_times_out_stalled_send_cf() {
	// In send_cf (CTS received) a full Tx FIFO gates poll() out mid-burst; tick() must still
	// abort if no CF goes out within N_Bs, so a bus drop mid-transfer can't wedge the link.
	mut l := Link{
		n_bs_us: 1000
	}
	mut buf := [max_payload]u8{}
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
	mut l := Link{
		n_bs_us: 1000
	}
	mut buf := [max_payload]u8{}
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

fn test_wftmax_255_does_not_wrap() {
	// Regression: wft_max at the u8 max must still abort — the counter must not wrap past
	// 255 back to 0 and tolerate WAITs forever.
	mut l := Link{
		n_bs_us: 1000
		wft_max: 255
	}
	mut buf := [max_payload]u8{}
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
	mut l := Link{
		n_bs_us: 1000
	}
	mut buf := [max_payload]u8{}
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


fn test_n_cr_times_out_stalled_receive() {
	mut l := Link{}
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
	mut dst := [max_payload]u8{}
	assert l.take(&dst[0]) == 0
}

fn test_n_cr_refreshes_per_cf() {
	mut l := Link{}
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
	mut dst := [max_payload]u8{}
	assert l.take(&dst[0]) == 20
	assert dst[6] == 6 && dst[19] == 19
}


fn test_n_cr_abort_clears_pending_fc() {
	mut l := Link{}
	l.init_defaults()
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
	mut l := Link{}
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
	mut dst := [max_payload]u8{}
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
	mut l := Link{}
	l.init_defaults()
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
	mut l := Link{}
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
	mut l := Link{
		n_bs_us: 1000
	}
	mut buf := [max_payload]u8{}
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
	mut l := Link{}
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
	mut l := Link{}
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
	mut server := Link{}
	mut tester := Link{}
	mut req := [max_payload]u8{}
	for i in 0 .. max_payload {
		req[i] = u8(i * 7)
	}
	assert tester.send(&req[0], max_payload)
	pump(mut tester, mut server, 1000)
	mut buf := [max_payload]u8{}
	assert server.take(&buf[0]) == max_payload
	for i in 0 .. max_payload {
		assert buf[i] == u8(i * 7)
	}
}

// our flow control carries the block size and STmin we grant, and comes again after each block
fn test_flow_control_carries_our_block_size_and_stmin() {
	mut l := Link{
		bs:    2
		stmin: 5
	}
	l.init_defaults()
	mut p := Pdu{}
	l.on_frame(0, Pdu{
		data: [u8(0x10), 30, 0, 0, 0, 0, 0, 0]!
	})
	assert l.poll(0, mut p)
	assert p.data[0] == 0x30 && p.data[1] == 2 && p.data[2] == 5
	l.on_frame(0, Pdu{
		data: [u8(0x21), 0, 0, 0, 0, 0, 0, 0]!
	})
	assert !l.poll(0, mut p) // mid-block: no flow control owed
	l.on_frame(0, Pdu{
		data: [u8(0x22), 0, 0, 0, 0, 0, 0, 0]!
	})
	assert l.poll(0, mut p) // block of 2 done: the next clear-to-send
	assert p.data[0] == 0x30 && p.data[1] == 2 && p.data[2] == 5
}

// a single frame claiming length 0 or above 7 is no message
fn test_a_single_frame_of_length_0_or_above_7_is_ignored() {
	mut l := Link{}
	mut buf := [max_payload]u8{}
	l.on_frame(0, Pdu{
		data: [u8(0x00), 1, 2, 3, 4, 5, 6, 7]!
	})
	assert l.take(&buf[0]) == 0
	l.on_frame(0, Pdu{
		data: [u8(0x08), 1, 2, 3, 4, 5, 6, 7]!
	})
	assert l.take(&buf[0]) == 0
}

// starts a 30-byte transmission and grants it `bs` / `stmin` with a clear-to-send at `now`
fn granted(bs u8, stmin u8, now u64) Link {
	mut l := Link{}
	l.init_defaults()
	buf := [30]u8{}
	assert l.send(&buf[0], 30)
	mut p := Pdu{}
	assert l.poll(0, mut p) // FF
	l.on_frame(now, Pdu{
		data: [u8(0x30), bs, stmin, 0, 0, 0, 0, 0]!
	})
	return l
}

// no more consecutive frames than the receiver's block size before its next flow control
fn test_transmission_honours_the_receivers_block_size() {
	mut l := granted(2, 0, 0)
	mut p := Pdu{}
	assert l.poll(0, mut p) && p.data[0] == 0x21
	assert l.poll(0, mut p) && p.data[0] == 0x22
	assert !l.poll(0, mut p) // waiting for the next clear-to-send
	l.on_frame(0, Pdu{
		data: [u8(0x30), 0, 0, 0, 0, 0, 0, 0]!
	})
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
	mut l := Link{}
	l.init_defaults()
	mut buf := [max_payload]u8{}
	l.on_frame(0, Pdu{
		data: [u8(0x10), 20, 1, 2, 3, 4, 5, 6]!
	})
	l.on_frame(0, Pdu{
		data: [u8(0x02), 0x3E, 0x00, 0, 0, 0, 0, 0]!
	})
	assert l.take(&buf[0]) == 2 && buf[0] == 0x3E
	mut p := Pdu{}
	assert !l.poll(0, mut p) // no clear-to-send for the reception it ended
	l.on_frame(0, Pdu{
		data: [u8(0x21), 7, 8, 9, 10, 11, 12, 13]!
	})
	assert l.take(&buf[0]) == 0 // the old reception does not resume
}

// a first frame announcing more than max_payload starts nothing and owes no flow control
fn test_an_oversize_first_frame_is_ignored() {
	mut l := Link{}
	l.init_defaults()
	mut p := Pdu{}
	total := max_payload + 1
	l.on_frame(0, Pdu{
		data: [u8(0x10 | (total >> 8)), u8(total & 0xFF), 0, 0, 0, 0, 0, 0]!
	})
	assert l.idle()
	assert !l.poll(0, mut p)
}

// the length each frame type needs before its bytes may be read
fn test_truncated_frames_by_type() {
	mut l := Link{}
	assert l.truncated(0x03, 3) && !l.truncated(0x03, 4) // SF of 3 needs 4 bytes
	assert l.truncated(0x10, 7) && !l.truncated(0x10, 8) // FF is always full
	assert l.truncated(0x30, 2) && !l.truncated(0x30, 3) // FC needs FS, BS, STmin
	l.rx_len = 20
	l.rx_pos = 6
	assert l.truncated(0x21, 7) // 14 bytes left: a CF must be full
	l.rx_pos = 18
	assert !l.truncated(0x23, 3) && l.truncated(0x23, 2) // the last 2 bytes need 3
}
