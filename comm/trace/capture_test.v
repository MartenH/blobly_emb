module trace

// The cross-core freeze seam (#271 r2): whichever ring trips its budget raises the shared cell,
// and every hook OBSERVES it per dispatch — so a peer stops within one handler of the event
// rather than at the end of a scheduler pass, where a core with more due handlers than its
// retained pre-window had already overwritten the triggering instant.
fn test_a_tripped_ring_raises_the_cell_and_the_peer_honours_it_next_dispatch() {
	mut cell := u32(0)
	mut ring_a := [8]Record{}
	mut buf_a := new_buffer(&ring_a[0], 8, .ring, 50)
	buf_a.start()
	mut a := Capture{
		buf: &buf_a
		budget_us: 100
		freeze: &cell
	}
	mut ring_b := [8]Record{}
	mut buf_b := new_buffer(&ring_b[0], 8, .ring, 50)
	buf_b.start()
	mut b := Capture{
		buf: &buf_b
		budget_us: 100
		freeze: &cell
	}
	fb_hook(voidptr(&b), 0, 0, 10) // in budget: records, raises nothing
	assert cell == 0
	assert buf_b.froze_cause() == freeze_none
	fb_hook(voidptr(&a), 0, 0, 500) // over budget: A triggers its own ring AND raises the cell
	assert cell == 1
	assert buf_a.froze_cause() == freeze_trigger
	fb_hook(voidptr(&b), 1, 0, 10) // B's very next dispatch observes the cell and triggers
	assert buf_b.froze_cause() == freeze_trigger
}

fn test_without_a_peer_cell_the_hook_triggers_locally_only() {
	mut ring := [8]Record{}
	mut buf := new_buffer(&ring[0], 8, .ring, 50)
	buf.start()
	mut c := Capture{
		buf: &buf
		budget_us: 100
	}
	fb_hook(voidptr(&c), 0, 0, 500)
	assert buf.froze_cause() == freeze_trigger // its own trigger still works with no peer wired
	
}

fn test_a_host_stopped_ring_does_not_raise_the_cell() {
	// stop is not a trip: a core the host stopped alone (mask one core) keeps dispatching, and
	// an over-budget handler there must not hand the still-capturing peer a phantom
	// freeze_trigger — the trip is judged on a CAPTURING ring, before trigger() moves state
	mut cell := u32(0)
	mut ring := [8]Record{}
	mut buf := new_buffer(&ring[0], 8, .ring, 50)
	buf.start()
	buf.stop()
	mut c := Capture{
		buf: &buf
		budget_us: 100
		freeze: &cell
	}
	fb_hook(voidptr(&c), 0, 0, 500) // over budget on the stopped ring
	assert cell == 0
	assert buf.froze_cause() == freeze_stop // the stop's cause survives, no phantom trigger
}

fn test_a_retired_cell_freezes_nobody() {
	// trip, retire (what the module does on a host arm), re-arm: the re-armed ring must keep
	// capturing — a stale observation after the clear froze the window the host just opened
	mut cell := u32(0)
	mut ring := [8]Record{}
	mut buf := new_buffer(&ring[0], 8, .ring, 50)
	buf.start()
	mut c := Capture{
		buf: &buf
		budget_us: 100
		freeze: &cell
	}
	fb_hook(voidptr(&c), 0, 0, 500) // trip: raises the cell, triggers the ring
	assert cell == 1
	cell = 0 // the module retires it on arm/start/reset (see multicore_cmd_test)
	buf.start() // ...and the host re-arms the ring
	fb_hook(voidptr(&c), 0, 0, 10)
	assert buf.froze_cause() == freeze_none // still capturing: nothing stale froze it
	assert cell == 0
}
