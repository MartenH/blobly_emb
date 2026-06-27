module nm

// @verifies REQ-NM-001, REQ-NM-002, REQ-NM-003, REQ-NM-004, REQ-NM-006, REQ-NM-007, REQ-NM-008
// Deterministic NM state-machine tests: drive `now` (microseconds) by hand.

fn timings() Timings {
	return Timings{
		msg_cycle_us:  100
		timeout_us:    300
		repeat_us:     200
		wait_sleep_us: 150
	}
}

fn test_active_wakeup_to_normal() {
	mut n := Nm{
		cfg: timings()
	}
	assert n.state == .bus_sleep
	n.request(0)
	assert n.state == .repeat_message
	n.tick(100) // before repeat_us elapses
	assert n.state == .repeat_message
	n.tick(200) // repeat_us elapsed, still requested -> normal
	assert n.state == .normal_operation
	assert n.awake()
}

fn test_passive_wakeup_then_ready_sleep() {
	mut n := Nm{
		cfg: timings()
	}
	n.on_rx(0) // heard another node while asleep
	assert n.state == .repeat_message
	n.tick(200) // repeat elapsed, not requested -> ready_sleep
	assert n.state == .ready_sleep
	assert n.awake()
}

fn test_release_leads_to_sleep() {
	mut n := Nm{
		cfg: timings()
	}
	n.request(0)
	n.tick(200) // -> normal_operation
	assert n.state == .normal_operation
	n.release()
	n.tick(250) // not requested -> ready_sleep
	assert n.state == .ready_sleep
	n.tick(600) // no rx since 0; timeout 300 exceeded -> prepare_bus_sleep
	assert n.state == .prepare_bus_sleep
	n.tick(760) // wait_sleep 150 from 600 -> bus_sleep
	assert n.state == .bus_sleep
	assert !n.awake()
}

fn test_rx_keeps_network_awake() {
	mut n := Nm{
		cfg: timings()
	}
	n.request(0)
	n.tick(200) // normal
	n.release()
	n.tick(250) // ready_sleep
	mut t := u64(300)
	for t < 3000 {
		n.on_rx(t) // another node keeps transmitting
		n.tick(t)
		assert n.state == .ready_sleep // never times out
		t += 100
	}
	assert n.awake()
}

fn test_tx_cadence() {
	mut n := Nm{
		cfg: timings()
	}
	n.request(0)
	assert n.tick(0) == true // armed: announce immediately on wakeup
	assert n.tick(50) == false // before next cycle
	assert n.tick(100) == true // one msg_cycle later
	assert n.state == .repeat_message // repeat_us (200) not yet elapsed
}

// A node that transmitted alone (no rx) must still wait `timeout` after its OWN
// last NM message before heading to sleep — not drop immediately on release.
fn test_lone_transmitter_waits_timeout() {
	mut n := Nm{
		cfg: timings()
	}
	n.request(0)
	mut t := u64(0)
	for t <= 5000 {
		n.tick(t) // active alone for a long time; last tx at 5000
		t += 50
	}
	assert n.state == .normal_operation
	n.release()
	n.tick(5050)
	assert n.state == .ready_sleep
	n.tick(5100) // only 100us since last tx (<300) -> must stay awake
	assert n.state == .ready_sleep
	n.tick(5400) // 400us since last tx (>=300) -> now head to sleep
	assert n.state == .prepare_bus_sleep
}

fn test_request_during_prepare_sleep_rewakes() {
	mut n := Nm{
		cfg: timings()
	}
	n.on_rx(0)
	n.tick(200) // ready_sleep
	n.tick(600) // prepare_bus_sleep
	assert n.state == .prepare_bus_sleep
	n.request(650) // application needs the bus again
	assert n.state == .repeat_message
	assert n.awake()
}
