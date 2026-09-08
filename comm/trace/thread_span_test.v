module trace

// note_thread is the bridge's equivalent of fb_hook (P3b, docs/trace-multicore.md §4.1): a thread
// that dispatches no FB handlers — the COM bridge drains codec/ISO-TP instead — would otherwise
// have an empty lane, because fb_hook never fires for it.

fn test_a_thread_span_lands_as_a_thread_record() {
	mut backing := [8]Record{}
	mut buf := new_buffer(&backing[0], 8, .ring, 50)
	buf.start()
	mut c := Capture{
		buf:   &buf
		start: 1000
	}

	c.note_thread(3, reason_yield, 1500, 40)

	assert buf.used() == 1
	r := buf.record_at(0)
	assert r.kind() == kind_thread, 'expected a THREAD record'
	assert r.id() == 3
	assert r.info() == reason_yield
	assert r.start_us() == 500, 'elapsed since the capture origin, got ${r.start_us()}'
}

// A drain cycle over budget freezes this ring, the same way an overrunning handler does — the
// bridge is a first-class traced entity, not a lane that only ever reacts to someone else.
fn test_an_over_budget_span_triggers_the_ring() {
	mut backing := [8]Record{}
	mut buf := new_buffer(&backing[0], 8, .ring, 50)
	buf.start()
	mut c := Capture{
		buf:       &buf
		start:     0
		budget_us: 500
	}

	c.note_thread(3, reason_yield, 100, 600) // 600us > the 500us budget

	// A ring with pre_pct = 50 ARMS the trigger and keeps recording until the post-window fills —
	// that is the flight-recorder split, not an immediate stop — so the freeze shows as the cause
	// while the state is still capturing. (pre_pct = 100 is the freeze-at-the-event case.)
	assert buf.froze_cause() == freeze_trigger, 'the over-budget cycle did not arm the trigger'

	// pre_pct = 100 keeps the whole window BEFORE the event, so there is no post-window to fill
	// and the ring stops at the trigger.
	mut b2 := [8]Record{}
	mut buf2 := new_buffer(&b2[0], 8, .ring, 100)
	buf2.start()
	mut c2 := Capture{
		buf:       &buf2
		start:     0
		budget_us: 500
	}
	c2.note_thread(3, reason_yield, 100, 600)
	assert buf2.state() == .frozen, 'with no post-window the ring should stop at the trigger'
}

// The u24 elapsed field must be re-anchored before it wraps, or every later record decodes
// against a base that is no longer in the window.
fn test_a_long_running_capture_re_anchors_the_epoch() {
	mut backing := [8]Record{}
	mut buf := new_buffer(&backing[0], 8, .ring, 50)
	buf.start()
	mut c := Capture{
		buf:   &buf
		start: 0
	}

	c.note_thread(3, reason_yield, 0x0100_0000, 10) // past the u24 ceiling

	assert buf.used() == 2, 'expected an epoch record before the thread record'
	assert buf.record_at(0).is_epoch(), 'the window was not re-anchored'
}
