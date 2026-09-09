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

fn test_an_overrun_filling_a_oneshots_final_slot_still_raises_the_cell() {
	// judged AFTER the push, the record that fills a oneshot's last free slot flips the state
	// to .full first, and the overrun that did it read as not-a-trip: the ring kept its own
	// cause but the peer was never told (codex #271 r3)
	mut cell := u32(0)
	mut ring := [4]Record{}
	mut buf := new_buffer(&ring[0], 4, .oneshot, 100)
	buf.start()
	mut c := Capture{
		buf: &buf
		budget_us: 100
		freeze: &cell
	}
	fb_hook(voidptr(&c), 0, 0, 10)
	fb_hook(voidptr(&c), 1, 0, 10)
	fb_hook(voidptr(&c), 2, 0, 10)
	assert cell == 0
	fb_hook(voidptr(&c), 3, 0, 500) // over budget, and fills the last slot
	assert cell == 1
	// ...and the initiating core reports the TRIGGER, not the fill's default stop cause —
	// its TraceRsp is how the host tells a triggered dump from a completed one
	assert buf.froze_cause() == freeze_trigger
}

fn test_an_epoch_consuming_the_final_slot_does_not_hide_the_trip() {
	// a u24 wrap makes the hook push an epoch BEFORE the FB record; on a oneshot with one
	// slot left that epoch completes the ring mid-hook, the FB record is dropped — and the
	// over-budget dispatch that arrived must still raise the cell and stamp the trigger
	// (codex #271 r6: the capturing test is taken at hook ENTRY, before either push)
	mut cell := u32(0)
	mut ring := [4]Record{}
	mut buf := new_buffer(&ring[0], 4, .oneshot, 100)
	buf.start()
	mut c := Capture{
		buf: &buf
		budget_us: 100
		freeze: &cell
	}
	fb_hook(voidptr(&c), 0, 0, 10)
	fb_hook(voidptr(&c), 1, 0, 10)
	fb_hook(voidptr(&c), 2, 0, 10) // three records: one slot left
	fb_hook(voidptr(&c), 3, 0x0100_0001, 500) // u24 wrap -> epoch fills the ring, and over budget
	assert cell == 1
	assert buf.froze_cause() == freeze_trigger
}

fn test_a_host_stop_racing_the_trip_wins() {
	// the owner can stop a ring between the hook's entry snapshot and its trip: the stop's
	// cause stands, no trigger is reported after it, and no peer freeze is raised for it —
	// trip() reports false and sync_freeze never fires (codex #271 r7)
	mut ring := [8]Record{}
	mut buf := new_buffer(&ring[0], 8, .ring, 50)
	buf.start()
	buf.stop() // the host stop, landing "mid-hook"
	assert buf.trip() == false
	assert buf.froze_cause() == freeze_stop

	// a oneshot that completed ON ITS OWN is the opposite case: freeze_full, and a trip
	// racing that fill may claim it
	mut ring2 := [2]Record{}
	mut buf2 := new_buffer(&ring2[0], 2, .oneshot, 100)
	buf2.start()
	buf2.push(new_fb(1, 0, 0, 1))
	buf2.push(new_fb(2, 0, 1, 1))
	assert buf2.froze_cause() == freeze_full
	assert buf2.trip() == true
	assert buf2.froze_cause() == freeze_trigger
}
