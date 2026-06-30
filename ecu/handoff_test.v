module ecu

// Conductor <- NM hand-off: the lifecycle's sleep/wake is driven by the REAL NM
// state machine, not synthetic flags. The mapping is one field —
//   Demand.network_busy = nm.awake()
// and that is enough: while any node needs the bus NM stays awake -> the ECU stays
// in Run; once the cluster times out NM reaches bus_sleep -> the ECU sleeps; an
// incoming NM frame wakes NM, which (via network_busy -> any_demand) wakes the ECU.
// So a separate wakeup line is only needed for non-NM sources (e.g. a KL15 pin).

import comm.nm

fn nm_timings() nm.Timings {
	return nm.Timings{
		msg_cycle_us:  100
		timeout_us:    300
		repeat_us:     200
		wait_sleep_us: 150
	}
}

// @verifies REQ-ECU-003, REQ-ECU-004
// Drive the Conductor from a live NM state machine across the full cycle:
// init -> Run, app demand keeps it awake, release lets it sleep, NM traffic wakes it.
fn test_conductor_follows_nm() {
	mut n := nm.Nm{
		cfg: nm_timings()
	}
	mut l := Lifecycle{}
	mut now := u64(0)

	// init done -> Run
	assert l.step(Demand{ init_done: true }) == .run

	// REQ-ECU-003: the application needs the network -> NM awake -> stays in Run
	n.request(now)
	n.tick(now)
	assert n.awake()
	assert l.step(Demand{ init_done: true, network_busy: n.awake() }) == .run

	// release; advance time, stepping the Conductor from NM each tick. While NM is
	// still winding down (ready_sleep/prepare_bus_sleep) it reports awake -> Run.
	n.release()
	mut reached_sleep := false
	for now <= 3000 {
		now += 50
		n.tick(now)
		m := l.step(Demand{ init_done: true, network_busy: n.awake() })
		if m == .sleep {
			reached_sleep = true
			break
		}
	}
	assert !n.awake(), 'NM should have reached bus_sleep once nothing needs the bus'
	assert reached_sleep, 'Conductor should sleep once NM reports the network idle'

	// REQ-ECU-004: a remote NM frame arrives -> NM passive wakeup -> Conductor wakes
	now += 50
	n.on_rx(now)
	assert n.awake()
	assert l.step(Demand{ init_done: true, network_busy: n.awake() }) == .run
}

// The Conductor must NOT sleep while NM is still awake, even with no app/diag demand
// — NM winding down (e.g. ready_sleep, kept alive by others) still holds Run.
fn test_no_sleep_while_nm_awake() {
	mut n := nm.Nm{
		cfg: nm_timings()
	}
	mut l := Lifecycle{
		mode: .run
	}
	n.request(0)
	n.tick(0)
	n.release() // released, but NM stays awake through its wind-down phases
	n.tick(50)
	assert n.awake()
	assert l.step(Demand{ init_done: true, network_busy: n.awake() }) == .run
}
