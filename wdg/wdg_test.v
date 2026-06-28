module wdg

// @verifies REQ-WDG-001, REQ-WDG-002, REQ-WDG-003, REQ-WDG-004

fn two_entities() Supervisor {
	mut s := Supervisor{
		n: 2
	}
	s.cfg[0] = Entity{
		period_us:   100
		deadline_us: 0
	}
	s.cfg[1] = Entity{
		period_us:   100
		deadline_us: 50
	}
	// both start alive at t=0
	s.checkpoint(0, 0)
	s.checkpoint(1, 0)
	return s
}

// REQ-WDG-001: the watchdog is serviced only while every entity is alive.
fn test_service_when_all_alive() {
	mut s := two_entities()
	s.checkpoint(0, 80)
	s.checkpoint(1, 80)
	assert s.service(90) // both checkpointed within their period
}

// REQ-WDG-002 + REQ-WDG-004: a missed alive checkpoint withholds the service.
fn test_missed_alive_withholds_service() {
	mut s := two_entities()
	s.checkpoint(0, 80) // entity 1 never re-checkpoints
	assert !s.service(150) // entity 1 is 150us since last alive > 100us period
	assert s.tripped
}

// REQ-WDG-003: an activity that exceeds its deadline withholds the service.
fn test_deadline_exceeded_withholds_service() {
	mut s := two_entities()
	s.checkpoint(0, 90)
	s.checkpoint(1, 90)
	s.start(1, 90) // entity 1 begins an activity with a 50us deadline
	assert s.service(120) // 30us in — still ok
	assert !s.service(150) // 60us in — past the 50us deadline
	assert s.tripped
}

// REQ-WDG-004: a trip latches — the service stays withheld even after the entity
// recovers, so the hardware watchdog reset is not averted by a transient miss.
fn test_trip_latches() {
	mut s := two_entities()
	s.checkpoint(0, 80) // entity 1 misses its window
	assert !s.service(200)
	assert s.tripped
	s.checkpoint(0, 210) // both recover...
	s.checkpoint(1, 210)
	assert !s.service(220) // ...but the latch holds -> HW watchdog still resets
}

// REQ-WDG-003: finishing the activity before the deadline keeps it healthy.
fn test_activity_finishes_in_time() {
	mut s := two_entities()
	s.checkpoint(0, 90)
	s.checkpoint(1, 90)
	s.start(1, 90)
	s.finish(1) // done well within the deadline
	s.checkpoint(0, 120)
	s.checkpoint(1, 120)
	assert s.service(130)
}
