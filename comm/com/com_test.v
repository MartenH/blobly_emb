module com

fn payload(b u8) [max_pdu]u8 {
	mut d := [max_pdu]u8{}
	d[0] = b
	return d
}

fn test_cyclic_sends_every_cycle() {
	mut t := TxState{
		mode:     .cyclic
		cycle_us: 100
	}
	assert t.should_send(0, payload(1), 1) // first send
	assert !t.should_send(50, payload(1), 1) // before cycle
	assert !t.should_send(50, payload(2), 1) // change is irrelevant for cyclic
	assert t.should_send(100, payload(2), 1) // cycle elapsed
}

fn test_event_sends_on_change_debounced() {
	mut t := TxState{
		mode:         .event
		min_delay_us: 100
	}
	assert t.should_send(0, payload(1), 1) // first value
	assert !t.should_send(1000, payload(1), 1) // unchanged -> never
	assert !t.should_send(50, payload(2), 1) // changed but within min_delay
	assert t.should_send(100, payload(2), 1) // changed and debounce elapsed
}

fn test_mixed_is_cyclic_plus_change() {
	mut t := TxState{
		mode:         .mixed
		cycle_us:     1000
		min_delay_us: 0
	}
	assert t.should_send(0, payload(1), 1) // first
	assert !t.should_send(10, payload(1), 1) // unchanged, within cycle
	assert t.should_send(20, payload(9), 1) // change -> immediate
	assert t.should_send(1020, payload(9), 1) // cyclic heartbeat even unchanged
}

fn test_triggered_only_on_trigger() {
	mut t := TxState{
		mode: .triggered
	}
	assert !t.should_send(0, payload(1), 1)
	t.trigger()
	assert t.should_send(0, payload(1), 1)
	assert !t.should_send(1, payload(1), 1)
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
