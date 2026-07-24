module com

// @verifies SYS-REQ-COMMS-003 REQ-COM-003 REQ-COM-004 REQ-COM-005 REQ-COM-006 REQ-E2E-002
// (REQ-COM-003/004: the cyclic/event/mixed/triggered should_send decisions incl. debounce
//  and backpressure; REQ-COM-005 and the timeout leg of REQ-E2E-002: the rx deadline
//  edge/latch/disable tests — the counter leg of E2E-002 lives in comm/e2e.)

fn payload(b u8) [max_pdu]u8 {
	mut d := [max_pdu]u8{}
	d[0] = b
	return d
}

// should_send is now a pure decision; a real send is committed by mark_sent(). These
// tests emulate the bridge: when should_send() is true and the (imagined) channel
// accepts the frame, they call mark_sent() with the same payload/time.
fn test_cyclic_sends_every_cycle() {
	mut t := TxState{
		mode:     .cyclic
		cycle_us: 100
	}
	assert t.should_send(0, payload(1), 1) // first send
	t.mark_sent(0, payload(1), 1)
	assert !t.should_send(50, payload(1), 1) // before cycle
	assert !t.should_send(50, payload(2), 1) // change is irrelevant for cyclic
	assert t.should_send(100, payload(2), 1) // cycle elapsed
	t.mark_sent(100, payload(2), 1)
}

fn test_event_sends_on_change_debounced() {
	mut t := TxState{
		mode:         .event
		min_delay_us: 100
	}
	assert t.should_send(0, payload(1), 1) // first value
	t.mark_sent(0, payload(1), 1)
	assert !t.should_send(1000, payload(1), 1) // unchanged -> never
	assert !t.should_send(50, payload(2), 1) // changed but within min_delay
	assert t.should_send(100, payload(2), 1) // changed and debounce elapsed
	t.mark_sent(100, payload(2), 1)
}

fn test_mixed_is_cyclic_plus_change() {
	mut t := TxState{
		mode:         .mixed
		cycle_us:     1000
		min_delay_us: 0
	}
	assert t.should_send(0, payload(1), 1) // first
	t.mark_sent(0, payload(1), 1)
	assert !t.should_send(10, payload(1), 1) // unchanged, within cycle
	assert t.should_send(20, payload(9), 1) // change -> immediate
	t.mark_sent(20, payload(9), 1)
	assert t.should_send(1020, payload(9), 1) // cyclic heartbeat even unchanged
	t.mark_sent(1020, payload(9), 1)
}

fn test_triggered_only_on_trigger() {
	mut t := TxState{
		mode: .triggered
	}
	assert !t.should_send(0, payload(1), 1)
	t.trigger()
	assert t.should_send(0, payload(1), 1)
	t.mark_sent(0, payload(1), 1)
	assert !t.should_send(1, payload(1), 1)
}

// REQ-COM-006: when the transmit path can't accept a frame (the bridge does NOT call
// mark_sent), an event or triggered PDU retains its request and retries until accepted;
// a cyclic PDU re-sends its current value at the next opportunity. should_send being a
// pure decision is exactly what makes the retry safe — nothing is consumed on a drop.
fn test_backpressure_retries_until_accepted() {
	// event: a change while the Tx path is full must not be lost
	mut e := TxState{
		mode:         .event
		min_delay_us: 0
	}
	assert e.should_send(0, payload(7), 1) // change -> wants to send
	// channel full: DON'T mark_sent. The change must still be pending next ticks.
	assert e.should_send(1, payload(7), 1)
	assert e.should_send(2, payload(7), 1)
	e.mark_sent(2, payload(7), 1) // accepted at last
	assert !e.should_send(3, payload(7), 1) // now consumed (unchanged)

	// triggered: a trigger survives a full Tx path until it is accepted
	mut g := TxState{
		mode: .triggered
	}
	g.trigger()
	assert g.should_send(0, payload(1), 1)
	assert g.should_send(5, payload(1), 1) // not dropped by the failed attempt
	g.mark_sent(5, payload(1), 1)
	assert !g.should_send(6, payload(1), 1) // trigger consumed only on success

	// cyclic: a missed cycle re-sends the current value at the next opportunity
	mut c := TxState{
		mode:     .cyclic
		cycle_us: 100
	}
	assert c.should_send(0, payload(1), 1)
	// full: skip mark_sent -> still due next tick (no stale queue, just the latest value)
	assert c.should_send(1, payload(1), 1)
	c.mark_sent(1, payload(1), 1)
	assert !c.should_send(50, payload(1), 1) // sent -> waits for the cycle
}

fn test_rx_deadline_edge() {
	mut r := RxState{
		timeout_us: 100
	}
	assert !r.expired(1000) // never received -> not expired
	r.on_receive(1000)
	assert !r.expired(1050) // within deadline
	assert r.expired(1200) // crossed -> true once
	assert !r.expired(1300) // stays latched until next receive
	r.on_receive(1300)
	assert !r.expired(1350)
}

fn test_rx_timeout_zero_disables() {
	mut r := RxState{
		timeout_us: 0
	}
	r.on_receive(0)
	assert !r.expired(1_000_000)
}
