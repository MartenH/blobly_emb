module trace

// The cross-core freeze seam (#271 r2): whichever ring trips its budget raises the shared cell,
// and every hook OBSERVES it per dispatch — so a peer stops within one handler of the event
// rather than at the end of a scheduler pass, where a core with more due handlers than its
// retained pre-window had already overwritten the triggering instant.
fn test_a_tripped_ring_raises_the_cell_and_the_peer_honours_it_next_dispatch() {
	mut cell := FreezeSync{}
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
	assert cell.word == 0
	assert buf_b.froze_cause() == freeze_none
	fb_hook(voidptr(&a), 0, 0, 500) // over budget: A triggers its own ring AND raises the cell
	assert cell.word == 1
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
	mut cell := FreezeSync{}
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
	assert cell.word == 0
	assert buf.froze_cause() == freeze_stop // the stop's cause survives, no phantom trigger
}

fn test_a_retired_cell_freezes_nobody() {
	// trip, retire (what the module does on a host arm: the next generation), re-arm: the re-armed
	// ring must keep capturing — a stale observation after the clear froze the window just opened
	mut cell := FreezeSync{}
	mut ring := [8]Record{}
	mut buf := new_buffer(&ring[0], 8, .ring, 50)
	buf.start()
	mut c := Capture{
		buf: &buf
		budget_us: 100
		freeze: &cell
	}
	fb_hook(voidptr(&c), 0, 0, 500) // trip: raises the cell, triggers the ring
	assert cell.word == 1 // generation 0, raised
	cell.word = 1 << 1 // the module retires it on arm/start/reset: the NEXT generation, unraised
	buf.start() // ...and the host re-arms the ring
	fb_hook(voidptr(&c), 0, 0, 10)
	assert buf.froze_cause() == freeze_none // still capturing: nothing stale froze it
	assert cell.word == 1 << 1
	assert c.gen == 1 // the hook adopted the new generation at entry
}

fn test_an_overrun_filling_a_oneshots_final_slot_still_raises_the_cell() {
	// judged AFTER the push, the record that fills a oneshot's last free slot flips the state
	// to .full first, and the overrun that did it read as not-a-trip: the ring kept its own
	// cause but the peer was never told (codex #271 r3)
	mut cell := FreezeSync{}
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
	assert cell.word == 0
	fb_hook(voidptr(&c), 3, 0, 500) // over budget, and fills the last slot
	assert cell.word == 1
	// ...and the initiating core reports the TRIGGER, not the fill's default stop cause —
	// its TraceRsp is how the host tells a triggered dump from a completed one
	assert buf.froze_cause() == freeze_trigger
}

fn test_an_epoch_consuming_the_final_slot_does_not_hide_the_trip() {
	// a u24 wrap makes the hook push an epoch BEFORE the FB record; on a oneshot with one
	// slot left that epoch completes the ring mid-hook, the FB record is dropped — and the
	// over-budget dispatch that arrived must still raise the cell and stamp the trigger
	// (codex #271 r6: the capturing test is taken at hook ENTRY, before either push)
	mut cell := FreezeSync{}
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
	assert cell.word == 1
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

// #273, the first ordering #271 could not close: a trip in the window a re-arm is ENDING. The hook
// adopted generation g at entry; the owner bumps to g+1 before the hook reaches its raise. The
// raise is a compare-and-swap against g, so it fails — the fresh window is not frozen by the one
// the host discarded — while the tripping ring's own trigger still stands.
fn test_a_raise_from_the_window_a_rearm_ended_is_refused() {
	mut cell := FreezeSync{}
	mut ring := [8]Record{}
	mut buf := new_buffer(&ring[0], 8, .ring, 50)
	buf.start()
	mut c := Capture{
		buf:       &buf
		budget_us: 100
		freeze:    &cell
	}
	c.adopt() // hook entry: generation 0
	cell.word = 1 << 1 // the owner's re-arm lands mid-hook: generation 1, unraised
	assert buf.trip()
	c.sync_freeze(true) // the hook's tail raises with ITS generation, 0
	assert cell.word == 1 << 1, 'a stale raise froze the new generation: ${cell.word}'
	assert buf.froze_cause() == freeze_trigger // the local trigger is unaffected
}

// ...and the second: a retirement and a raise can no longer cross, because retiring IS moving to
// the next generation — there is no clear left to run after a fresh window's raise. A trip in the
// new generation raises it, and a peer that adopted the same generation honours it.
fn test_a_raise_in_the_new_generation_stands_and_is_honoured() {
	mut cell := FreezeSync{}
	cell.word = 3 << 1 // three re-arms so far
	mut ring_a := [8]Record{}
	mut buf_a := new_buffer(&ring_a[0], 8, .ring, 50)
	buf_a.start()
	mut a := Capture{
		buf:       &buf_a
		budget_us: 100
		freeze:    &cell
	}
	mut ring_b := [8]Record{}
	mut buf_b := new_buffer(&ring_b[0], 8, .ring, 50)
	buf_b.start()
	mut b := Capture{
		buf:       &buf_b
		budget_us: 100
		freeze:    &cell
	}
	fb_hook(voidptr(&a), 0, 0, 500)
	assert cell.word == (3 << 1) | 1
	fb_hook(voidptr(&b), 0, 0, 10) // adopts generation 3 at entry, then observes its raise
	assert buf_b.froze_cause() == freeze_trigger
}

// A re-arm addressed to the satellite is POSTED (rearm, then the generation) and performed by the
// satellite's own next dispatch — the restart can no longer straddle a dispatch, which is where the
// stale raise came from. A later re-arm that did not address it is adopted without a restart, and
// every adoption is acknowledged for the owner.
fn test_the_satellite_restarts_its_own_ring_on_a_posted_rearm() {
	mut cell := FreezeSync{}
	mut ring := [8]Record{}
	mut buf := new_buffer(&ring[0], 8, .ring, 50)
	buf.start()
	mut s := Capture{
		buf:       &buf
		budget_us: 100
		freeze:    &cell
		satellite: true
	}
	for i in 0 .. 3 {
		fb_hook(voidptr(&s), i, u64(i), 10)
	}
	buf.stop()
	assert buf.used() == 3
	cell.rearm = 1 // posted FIRST...
	cell.word = 1 << 1 // ...then the generation
	fb_hook(voidptr(&s), 0, 10, 10) // the satellite's next dispatch performs it, on its own thread
	assert buf.state() == .capturing
	assert buf.used() == 1, 'the old window survived the re-arm'
	assert cell.ack == 1
	cell.word = 2 << 1 // a re-arm that did NOT address the satellite: adopted, no restart
	fb_hook(voidptr(&s), 0, 11, 10)
	assert buf.used() == 2
	assert cell.ack == 2
}
