module uds

// RoutineControl (0x31) and responsePending (0x78) in an application server, on a synthetic clock,
// with the FB's side of the two cells played by RoutineFb as the generated glue drives it.

const t0 = u64(1_000_000)

// rid_sync: a synchronous routine (start_in 1, start_out 2, results), extended, no level
const rid_sync = u16(0x0201)

// rid_async: an asynchronous routine with stop and results (results_out 2), extended, level 1
const rid_async = u16(0x0202)

// rid_locked: a synchronous routine with neither stop nor results, extended, level 1
const rid_locked = u16(0x0203)

fn routine_server() Server {
	mut s := Server{}
	s.init(256)
	s.routines[0] = Routine{
		id:          rid_sync
		sessions:    in_extended
		start_in:    1
		start_out:   2
		results:     true
		results_out: 2
		timeout_us:  10_000_000
	}
	s.routines[1] = Routine{
		id:          rid_async
		sessions:    in_extended
		security:    1
		async:       true
		stop:        true
		results:     true
		results_out: 2
		timeout_us:  10_000_000
	}
	s.routines[2] = Routine{
		id:         rid_locked
		sessions:   in_extended
		security:   1
		timeout_us: 10_000_000
	}
	s.nroutines = 3
	mut r := &ReferenceSecurity{}
	s.security = r.ops(0x1234_5678)
	s.security_levels = 0x01
	s.tick(t0)
	assert rcall(mut s, [u8(0x10), 0x03])[0] == 0x50
	return s
}

// rcall: one physical request, its answer (empty = none)
fn rcall(mut s Server, req []u8) []u8 {
	mut resp := [256]u8{}
	n := s.handle(&req[0], req.len, &resp[0])
	mut out := []u8{}
	for i in 0 .. n {
		out << resp[i]
	}
	return out
}

fn unlock(mut s Server) {
	seed := rcall(mut s, [u8(0x27), 0x01])
	assert seed[0] == 0x67
	mut req := [u8(0x27), 0x02]
	req << seed[2..].map(it ^ 0xFF) // the reference key
	assert rcall(mut s, req) == [u8(0x67), 0x02]
}

fn rq(sub u8, id u16, option []u8) []u8 {
	mut out := [u8(0x31), sub, u8(id >> 8), u8(id)]
	out << option
	return out
}

fn step(mut s Server, cap int) []u8 {
	mut resp := [256]u8{}
	n := s.pending_step(&resp[0], cap)
	mut out := []u8{}
	for i in 0 .. n {
		out << resp[i]
	}
	return out
}

fn functional(mut s Server, req []u8) []u8 {
	mut resp := [256]u8{}
	n := s.handle_functional(&req[0], req.len, &resp[0])
	mut out := []u8{}
	for i in 0 .. n {
		out << resp[i]
	}
	return out
}

// Fb plays routine i's FB through its two cells, as the generated glue does: the request cell read
// and taken, the handler's state reported, the record copied only when a state was written, the
// result cell published.
struct Fb {
mut:
	f RoutineFb
}

fn (mut fb Fb) dispatch(mut s Server, i int, state RoutineState, nrc u8, rec []u8) RoutineOp {
	op := fb.f.take(&s.routines[i].req)
	if fb.f.report(state, nrc) {
		for k in 0 .. max_routine_record {
			fb.f.res.data[k] = if k < rec.len { rec[k] } else { u8(0) }
		}
	}
	s.routines[i].res = fb.f.res
	return op
}

const pending_78 = [u8(0x7F), 0x31, 0x78]

// @verifies REQ-DIAG-080
// The NRC order of 0x31, after the service row's checks: ISO 14229-1's general checks of a request
// with a sub-function (length 2, the sub-function), then 0x31's: length 4, identifier and session,
// the routine's level, a sub-function it does not offer, the exact length, the sequence.
fn test_routine_control_refuses_in_its_order() {
	mut s := routine_server()
	cases := [
		[[u8(0x31)], [u8(0x7F), 0x31, 0x13]], // no sub-function
		[[u8(0x31), 0x7F], [u8(0x7F), 0x31, 0x12]], // the sub-function before 0x31's own length
		[[u8(0x31), 0x04, 0x02], [u8(0x7F), 0x31, 0x12]],
		[[u8(0x31), 0x01, 0x02], [u8(0x7F), 0x31, 0x13]], // a sub-function, but shorter than 4
		[[u8(0x31), 0x03], [u8(0x7F), 0x31, 0x13]],
		[rq(0x00, rid_sync, []), [u8(0x7F), 0x31, 0x12]], // sub-function 00
		[rq(0x04, rid_sync, []), [u8(0x7F), 0x31, 0x12]], // sub-function 04
		[rq(0x01, 0x0300, [u8(1)]), [u8(0x7F), 0x31, 0x31]], // not configured
		[rq(0x01, 0x0300, []), [u8(0x7F), 0x31, 0x31]],
		[rq(0x03, 0x0300, [u8(1), 2]), [u8(0x7F), 0x31, 0x31]], // the identifier before the length
		[rq(0x01, rid_async, []), [u8(0x7F), 0x31, 0x33]], // its level
		[rq(0x01, rid_async, [u8(0xFF)]), [u8(0x7F), 0x31, 0x33]], // its level before the length
		[rq(0x02, rid_async, []), [u8(0x7F), 0x31, 0x33]], // its level before the sequence
		[rq(0x02, rid_locked, [u8(1)]), [u8(0x7F), 0x31, 0x33]], // before an unoffered one and the length
		[rq(0x02, rid_sync, []), [u8(0x7F), 0x31, 0x12]], // a sync routine offers no stop
		[rq(0x02, rid_sync, [u8(0)]), [u8(0x7F), 0x31, 0x12]], // an unoffered one before the length
		[rq(0x01, rid_sync, []), [u8(0x7F), 0x31, 0x13]], // its option record is one byte
		[rq(0x01, rid_sync, [u8(1), 2]), [u8(0x7F), 0x31, 0x13]],
		[rq(0x03, rid_sync, [u8(1)]), [u8(0x7F), 0x31, 0x13]], // 03 carries none
		[rq(0x03, rid_sync, []), [u8(0x7F), 0x31, 0x24]], // results before any start
	]
	for c in cases {
		assert rcall(mut s, c[0]) == c[1], '${c[0]}'
	}
	// a routine offering neither stop nor results: both 0x12, after the identifier and the level
	s.routines[0].results = false
	assert rcall(mut s, rq(0x03, rid_sync, [])) == [u8(0x7F), 0x31, 0x12]
	assert rcall(mut s, rq(0x03, 0x0300, [])) == [u8(0x7F), 0x31, 0x31]
	s.routines[0].results = true
	// the routine's level before a sub-function it does not offer
	for sub in [u8(0x02), 0x03] {
		assert rcall(mut s, rq(sub, rid_locked, [])) == [u8(0x7F), 0x31, 0x33], 'sub ${sub}'
	}
	// an identifier not allowed in the active session is out of range, as one not configured —
	// before its level
	assert rcall(mut s, [u8(0x10), 0x01])[0] == 0x50
	assert rcall(mut s, rq(0x01, rid_sync, [u8(1)])) == [u8(0x7F), 0x31, 0x31]
	assert rcall(mut s, rq(0x01, rid_locked, [])) == [u8(0x7F), 0x31, 0x31]
	assert rcall(mut s, rq(0x02, rid_locked, [])) == [u8(0x7F), 0x31, 0x31]
	assert s.routines[0].req.seq == 0, 'a refused request reached the FB'
	// the sequence: a start while running, a stop while not
	assert rcall(mut s, [u8(0x10), 0x03])[0] == 0x50
	unlock(mut s)
	for sub in [u8(0x02), 0x03] {
		assert rcall(mut s, rq(sub, rid_locked, [])) == [u8(0x7F), 0x31, 0x12], 'unlocked, sub ${sub}'
		assert rcall(mut s, rq(sub, rid_locked, [u8(1)])) == [u8(0x7F), 0x31, 0x12], 'unlocked, sub ${sub}, a byte more'
	}
	// the length before the sequence
	assert rcall(mut s, rq(0x02, rid_async, [u8(1)])) == [u8(0x7F), 0x31, 0x13]
	assert rcall(mut s, rq(0x03, rid_async, [u8(1)])) == [u8(0x7F), 0x31, 0x13]
	assert rcall(mut s, rq(0x02, rid_async, [])) == [u8(0x7F), 0x31, 0x24]
	mut fb := Fb{}
	assert rcall(mut s, rq(0x01, rid_async, [])) == pending_78
	fb.dispatch(mut s, 1, .running, 0, [u8(0), 1])
	assert step(mut s, 256) == [u8(0x71), 0x01, 0x02, 0x02, 0x01]
	assert rcall(mut s, rq(0x01, rid_async, [])) == [u8(0x7F), 0x31, 0x24]
}

// @verifies REQ-DIAG-080
fn test_a_server_without_routines_does_not_serve_0x31() {
	mut s := Server{}
	s.init(256)
	assert rcall(mut s, rq(0x01, rid_sync, [u8(1)])) == [u8(0x7F), 0x31, 0x11]
}

// @verifies REQ-DIAG-080
// A functional 0x31 is ignored outright — unanswered, unperformed — and keeps the session alive.
fn test_a_functional_routine_control_is_ignored() {
	mut s := routine_server()
	s.tick(t0 + 3_000_000)
	assert functional(mut s, rq(0x01, rid_sync, [u8(1)])).len == 0
	assert s.routines[0].req.seq == 0
	assert !s.pending()
	assert s.last_rx_us == t0 + 3_000_000
}

// accept_sync: a start of rid_sync answered positively (done), so 03 is served
fn accept_sync(mut s Server, mut fb Fb) {
	assert rcall(mut s, rq(0x01, rid_sync, [u8(1)])) == pending_78
	fb.dispatch(mut s, 0, .done, 0, [u8(0), 3])
	assert step(mut s, 256)[4] == routine_info_done
	assert rcall(mut s, rq(0x03, rid_sync, [])) == [u8(0x71), 0x03, 0x02, 0x01, 0x02, 0x00, 0x03]
}

// @verifies REQ-DIAG-080 REQ-DIAG-085
// 03 answers from the FB's latest report once the latest start was answered positively: not before
// any start, not after a start that timed out or was refused, but through a server-issued stop not
// yet acknowledged and a session re-entry; reset_state ends it.
fn test_results_follow_the_latest_start_answered() {
	mut s := routine_server()
	mut fb := Fb{}
	assert rcall(mut s, rq(0x03, rid_sync, [])) == [u8(0x7F), 0x31, 0x24]
	// each case below follows a start answered positively, so it is the new start that ends 03
	// a start the FB refuses
	accept_sync(mut s, mut fb)
	assert rcall(mut s, rq(0x01, rid_sync, [u8(0)])) == pending_78
	assert rcall(mut s, rq(0x03, rid_sync, [])).len == 0, 'dropped while owed'
	fb.dispatch(mut s, 0, .refused, 0x31, [])
	assert step(mut s, 256) == [u8(0x7F), 0x31, 0x31]
	assert rcall(mut s, rq(0x03, rid_sync, [])) == [u8(0x7F), 0x31, 0x24], 'results of a refused start'
	// a start that times out
	accept_sync(mut s, mut fb)
	assert rcall(mut s, rq(0x01, rid_sync, [u8(5)])) == pending_78
	fb.dispatch(mut s, 0, .running, 0, [u8(0), 1])
	s.tick(t0 + 10_000_000)
	assert step(mut s, 256) == [u8(0x7F), 0x31, 0x22]
	assert rcall(mut s, rq(0x03, rid_sync, [])) == [u8(0x7F), 0x31, 0x24]
	// an async start accepted: 03 reads each report, a rising count
	unlock(mut s)
	assert rcall(mut s, rq(0x01, rid_async, [])) == pending_78
	mut fa := Fb{}
	fa.dispatch(mut s, 1, .running, 0, [u8(0), 1])
	assert step(mut s, 256)[4] == routine_info_running
	fa.dispatch(mut s, 1, .running, 0, [u8(0), 7])
	assert rcall(mut s, rq(0x03, rid_async, [])) == [u8(0x71), 0x03, 0x02, 0x02, 0x01, 0x00, 0x07]
	// a session re-entry asks it to stop; until its FB acknowledges, 03 reads the report it has
	assert rcall(mut s, [u8(0x10), 0x03])[0] == 0x50
	assert s.routines[1].req.op == .stop
	unlock(mut s)
	assert rcall(mut s, rq(0x03, rid_async, [])) == [u8(0x71), 0x03, 0x02, 0x02, 0x01, 0x00, 0x07]
	assert fa.dispatch(mut s, 1, .stopped, 0, [u8(0), 8]) == .stop
	assert rcall(mut s, rq(0x03, rid_async, [])) == [u8(0x71), 0x03, 0x02, 0x02, 0x03, 0x00, 0x08]
	// and a reset ends it
	s.reset_state()
	assert rcall(mut s, [u8(0x10), 0x03])[0] == 0x50
	unlock(mut s)
	assert rcall(mut s, rq(0x03, rid_async, [])) == [u8(0x7F), 0x31, 0x24]
}

// @verifies REQ-DIAG-081
// The FB sees each request once, in one dispatch; what it reports is stamped with the request it
// answers and stands until it reports another state; a result of an earlier request is stale.
fn test_the_fb_sees_each_request_once_and_its_report_stands() {
	mut s := routine_server()
	assert rcall(mut s, rq(0x01, rid_sync, [u8(0x14)])) == pending_78
	assert s.routines[0].req.seq == 1
	assert s.routines[0].req.op == .start
	assert s.routines[0].req.data[0] == 0x14
	mut f := RoutineFb{}
	assert f.take(&RoutineRequest{}) == .none, 'seq 0 is "never asked"'
	assert !f.report(.done, 0), 'nothing taken, nothing to report on'
	assert f.take(&s.routines[0].req) == .start
	assert f.take(&s.routines[0].req) == .none, 'the same request twice'
	assert f.report(.running, 0)
	f.res.data[0] = 9
	assert !f.report(.none, 0)
	assert f.res.state == .running && f.res.data[0] == 9 && f.res.seq == 1, 'a quiet dispatch changed it'
	// a refusal stamps the request with an NRC a routine may give, and leaves the state and record
	assert !f.report(.refused, 0x11)
	assert f.res.nrc == 0x22 && f.res.state == .running && f.res.data[0] == 9 && f.res.seq == 1
	assert f.report(.done, 0)
	assert f.res.nrc == 0x22 && f.res.state == .done, 'a state after it keeps the refusal of the request'
	// a result of an earlier request is ignored: the server waits on the latest
	s.routines[0].res = f.res
	s.routines[0].res.seq = 0
	assert !s.routines[0].fresh()
	s.routines[0].res = RoutineResult{
		seq: 1
	}
	assert !s.routines[0].fresh(), 'a state of none is no report'
	s.routines[0].res.nrc = 0x22
	assert s.routines[0].fresh(), 'a refusal is a report'
	// the sequence number skips 0 when it wraps, and a stop is still handed over across the wrap
	mut r := Routine{}
	r.req.seq = 0xFFFF
	r.res.seq = 0xFFFF
	r.ask(.stop, unsafe { nil }, 0)
	assert r.req.seq == 1 && r.req.stop == 1
	r.ask(.start, unsafe { nil }, 0)
	assert r.req.seq == 2 && r.req.stop == 1
	mut g := RoutineFb{
		seen: 0xFFFF
	}
	assert g.take(&r.req) == .stop
	assert g.take(&r.req) == .start
	assert g.take(&r.req) == .none
}

// @verifies REQ-DIAG-081 REQ-DIAG-085
// A stop the server issues itself reaches the FB before a start written after it — in a dispatch of
// its own, its report stale to the start still owed — whether it came from a session entry or a
// timeout; stops written before the FB took the first are one stop; a start the server stopped
// before the FB took it is never handed over; and the cell forgets a stop once the FB answered the
// latest request.
fn test_a_server_issued_stop_reaches_the_fb_before_the_next_start() {
	mut s := routine_server()
	unlock(mut s)
	mut fa := Fb{}
	assert rcall(mut s, rq(0x01, rid_async, [])) == pending_78
	assert fa.dispatch(mut s, 1, .running, 0, [u8(0), 1]) == .start
	assert step(mut s, 256)[4] == routine_info_running
	// a session entry asks it to stop — twice is one stop — and a start follows before the FB runs
	assert rcall(mut s, [u8(0x10), 0x03])[0] == 0x50
	stop_seq := s.routines[1].req.seq
	assert rcall(mut s, [u8(0x10), 0x03])[0] == 0x50
	assert s.routines[1].req.seq == stop_seq, 'a second stop over one not taken'
	unlock(mut s)
	assert rcall(mut s, rq(0x01, rid_async, [])) == pending_78
	assert s.routines[1].req.op == .start && s.routines[1].req.stop == stop_seq
	assert fa.dispatch(mut s, 1, .stopped, 0, [u8(0), 2]) == .stop, 'the stop first'
	assert step(mut s, 256).len == 0, 'the stop answered: the start is still owed'
	assert s.pending()
	assert fa.dispatch(mut s, 1, .running, 0, [u8(0), 1]) == .start, 'then the start'
	assert step(mut s, 256) == [u8(0x71), 0x01, 0x02, 0x02, routine_info_running]
	assert fa.dispatch(mut s, 1, .running, 0, [u8(0), 2]) == .none
	// a timed-out synchronous start: the stop the timeout asks reaches the FB before the next start
	mut fs := Fb{}
	assert rcall(mut s, rq(0x01, rid_sync, [u8(0xFF)])) == pending_78
	assert fs.dispatch(mut s, 0, .running, 0, []) == .start
	s.tick(t0 + 10_000_000)
	assert step(mut s, 256) == [u8(0x7F), 0x31, 0x22]
	assert rcall(mut s, rq(0x01, rid_sync, [u8(1)])) == pending_78
	assert fs.dispatch(mut s, 0, .stopped, 0, []) == .stop
	assert step(mut s, 256).len == 0
	assert fs.dispatch(mut s, 0, .done, 0, [u8(0), 2]) == .start
	assert step(mut s, 256)[4] == routine_info_done
	// answered on the latest request: the next request no longer carries the stop
	assert rcall(mut s, rq(0x01, rid_sync, [u8(1)])) == pending_78
	assert s.routines[0].req.stop == 0
	// a start stopped before the FB took it (the session ending under it): only the stop arrives
	s.end_session()
	assert step(mut s, 256) == [u8(0x7F), 0x31, 0x22]
	assert fs.dispatch(mut s, 0, .stopped, 0, []) == .stop
	assert fs.dispatch(mut s, 0, .none, 0, []) == .none
}

// @verifies REQ-DIAG-081 REQ-DIAG-085
// The server does not wait for a stop it issued: an FB whose stop takes several dispatches is
// handed the next start while still stopping, and refuses it (0x24) until it has stopped.
fn test_a_start_can_reach_an_fb_still_stopping() {
	mut s := routine_server()
	unlock(mut s)
	mut fa := Fb{}
	assert rcall(mut s, rq(0x01, rid_async, [])) == pending_78
	fa.dispatch(mut s, 1, .running, 0, [u8(0), 1])
	assert step(mut s, 256)[4] == routine_info_running
	assert rcall(mut s, [u8(0x10), 0x03])[0] == 0x50
	unlock(mut s)
	assert rcall(mut s, rq(0x01, rid_async, [])) == pending_78, 'served before the stop is acknowledged'
	assert fa.dispatch(mut s, 1, .running, 0, [u8(0), 2]) == .stop, 'winding down'
	assert step(mut s, 256).len == 0
	assert fa.dispatch(mut s, 1, .refused, 0x24, []) == .start, 'the start, while still stopping'
	assert step(mut s, 256) == [u8(0x7F), 0x31, 0x24]
	assert rcall(mut s, rq(0x01, rid_async, [])) == [u8(0x7F), 0x31, 0x24], 'still running'
	fa.dispatch(mut s, 1, .stopped, 0, [u8(0), 3])
	assert rcall(mut s, rq(0x01, rid_async, [])) == pending_78, 'stopped: a start is served'
	assert fa.dispatch(mut s, 1, .running, 0, [u8(0), 1]) == .start
	assert step(mut s, 256)[4] == routine_info_running
}

// @verifies REQ-DIAG-080 REQ-DIAG-081 REQ-DIAG-085
// A stop the FB refuses leaves the routine running: its state and record stand, so 03 still reads
// them, a start is 0x24, a stop may be asked again, and a session entry asks it to stop again.
fn test_a_refused_stop_leaves_the_routine_running() {
	mut s := routine_server()
	unlock(mut s)
	mut fa := Fb{}
	assert rcall(mut s, rq(0x01, rid_async, [])) == pending_78
	fa.dispatch(mut s, 1, .running, 0, [u8(0), 7])
	assert step(mut s, 256)[4] == routine_info_running
	assert rcall(mut s, rq(0x02, rid_async, [])) == pending_78
	assert fa.dispatch(mut s, 1, .refused, 0x22, []) == .stop
	assert step(mut s, 256) == [u8(0x7F), 0x31, 0x22]
	assert rcall(mut s, rq(0x03, rid_async, [])) == [u8(0x71), 0x03, 0x02, 0x02, routine_info_running,
		0x00, 0x07]
	assert rcall(mut s, rq(0x01, rid_async, [])) == [u8(0x7F), 0x31, 0x24], 'a start while it runs'
	assert rcall(mut s, rq(0x02, rid_async, [])) == pending_78, 'a stop may be asked again'
	assert fa.dispatch(mut s, 1, .refused, 0x22, []) == .stop
	assert step(mut s, 256) == [u8(0x7F), 0x31, 0x22]
	// a refusal followed by progress before the server reads the cell: still answered as refused
	assert rcall(mut s, rq(0x02, rid_async, [])) == pending_78
	assert fa.f.take(&s.routines[1].req) == .stop
	assert !fa.f.report(.refused, 0x22)
	assert fa.f.report(.running, 0)
	fa.f.res.data[1] = 9
	s.routines[1].res = fa.f.res
	assert step(mut s, 256) == [u8(0x7F), 0x31, 0x22]
	assert rcall(mut s, rq(0x03, rid_async, [])) == [u8(0x71), 0x03, 0x02, 0x02, routine_info_running,
		0x00, 0x09]
	seq := s.routines[1].req.seq
	assert rcall(mut s, [u8(0x10), 0x03])[0] == 0x50
	assert s.routines[1].req.op == .stop && s.routines[1].req.seq == seq + 1, 'the session entry asks again'
	assert fa.dispatch(mut s, 1, .stopped, 0, [u8(0), 8]) == .stop
	assert s.routines[1].res.nrc == 0, 'the next request clears the refusal'
	unlock(mut s)
	assert rcall(mut s, rq(0x03, rid_async, [])) == [u8(0x71), 0x03, 0x02, 0x02, routine_info_stopped,
		0x00, 0x08]
}

// @verifies REQ-DIAG-082
// A stop not answered within the routine's timeout: responsePending meanwhile, then 0x22 at the
// deadline; no second stop is asked over the one the FB has not answered.
fn test_a_stop_not_answered_within_its_timeout() {
	mut s := routine_server()
	unlock(mut s)
	mut fa := Fb{}
	assert rcall(mut s, rq(0x01, rid_async, [])) == pending_78
	fa.dispatch(mut s, 1, .running, 0, [])
	assert step(mut s, 256)[0] == 0x71
	assert rcall(mut s, rq(0x02, rid_async, [])) == pending_78
	seq := s.routines[1].req.seq
	assert fa.dispatch(mut s, 1, .running, 0, []) == .stop
	s.tick(t0 + 10_000_000 - 1)
	assert step(mut s, 256) == pending_78
	assert step(mut s, 256).len == 0, 'a stop still running is owed until its timeout'
	s.tick(t0 + 10_000_000)
	assert step(mut s, 256) == [u8(0x7F), 0x31, 0x22]
	assert s.routines[1].req.seq == seq
	assert s.routines[1].accepted, 'a stop that timed out leaves the start answered'
}

// @verifies REQ-DIAG-082 REQ-DIAG-083
// A synchronous start is owed until the FB reports it done, its record in the answer; meanwhile a
// responsePending at most every 4 s.
fn test_a_sync_start_is_answered_when_done() {
	mut s := routine_server()
	mut fb := Fb{}
	assert rcall(mut s, rq(0x01, rid_sync, [u8(40)])) == pending_78
	assert s.pending()
	assert step(mut s, 256).len == 0
	assert fb.dispatch(mut s, 0, .running, 0, [u8(0), 1]) == .start
	s.tick(t0 + 50_000)
	assert step(mut s, 256).len == 0, 'a running sync routine is not answered'
	s.tick(t0 + pending_repeat_us - 1)
	assert step(mut s, 256).len == 0
	s.tick(t0 + pending_repeat_us)
	assert step(mut s, 256) == pending_78
	assert step(mut s, 256).len == 0
	s.tick(t0 + 2 * pending_repeat_us)
	assert step(mut s, 256) == pending_78
	fb.dispatch(mut s, 0, .done, 0, [u8(0), 40])
	assert step(mut s, 256) == [u8(0x71), 0x01, 0x02, 0x01, routine_info_done, 0x00, 40]
	assert !s.pending()
	assert s.routines[0].accepted
	assert rcall(mut s, rq(0x03, rid_sync, [])) == [u8(0x71), 0x03, 0x02, 0x01, 0x02, 0x00, 40]
}

// @verifies REQ-DIAG-082
// An asynchronous start is answered at the FB's first report; a stop is owed until the FB reports
// the routine no longer running.
fn test_an_async_start_and_its_stop() {
	mut s := routine_server()
	unlock(mut s)
	mut fb := Fb{}
	assert rcall(mut s, rq(0x01, rid_async, [])) == pending_78
	fb.dispatch(mut s, 1, .running, 0, [u8(0), 1])
	assert step(mut s, 256) == [u8(0x71), 0x01, 0x02, 0x02, routine_info_running]
	assert rcall(mut s, rq(0x02, rid_async, [])) == pending_78
	assert fb.dispatch(mut s, 1, .running, 0, [u8(0), 2]) == .stop
	assert step(mut s, 256).len == 0, 'still running: the stop is owed'
	fb.dispatch(mut s, 1, .stopped, 0, [u8(0), 2])
	assert step(mut s, 256) == [u8(0x71), 0x02, 0x02, 0x02, routine_info_stopped]
	assert rcall(mut s, rq(0x02, rid_async, [])) == [u8(0x7F), 0x31, 0x24]
}

// @verifies REQ-DIAG-082
// An FB's refusal is answered with its NRC where a routine may give it, else conditionsNotCorrect;
// a failure is a positive answer.
fn test_refusals_and_failures() {
	for c in [[u8(0x31), 0x31], [u8(0x22), 0x22], [u8(0x24), 0x24], [u8(0x72), 0x72],
		[u8(0x78), 0x22], [u8(0x11), 0x22], [u8(0x00), 0x22]] {
		mut s := routine_server()
		mut fb := Fb{}
		assert rcall(mut s, rq(0x01, rid_sync, [u8(1)])) == pending_78
		fb.dispatch(mut s, 0, .refused, c[0], [])
		assert step(mut s, 256) == [u8(0x7F), 0x31, c[1]], 'NRC 0x${c[0].hex()}'
	}
	mut s := routine_server()
	mut fb := Fb{}
	assert rcall(mut s, rq(0x01, rid_sync, [u8(1)])) == pending_78
	fb.dispatch(mut s, 0, .failed, 0, [u8(0xAB), 0xCD])
	assert step(mut s, 256) == [u8(0x71), 0x01, 0x02, 0x01, routine_info_failed, 0xAB, 0xCD]
}

// @verifies REQ-DIAG-082 REQ-DIAG-084
// A start not answered within its timeout: at the deadline the FB is asked to stop by the tick
// alone, and the owed answer becomes 0x22; a transport that never takes it is given up P2* later.
fn test_a_timeout_stops_the_fb_and_answers_0x22() {
	mut s := routine_server()
	mut fb := Fb{}
	assert rcall(mut s, rq(0x01, rid_sync, [u8(0xFF)])) == pending_78
	fb.dispatch(mut s, 0, .running, 0, [])
	s.tick(t0 + 10_000_000 - 1)
	assert s.routines[0].req.op == .start
	s.tick(t0 + 10_000_000)
	assert s.routines[0].req.op == .stop, 'the FB is told at the deadline itself'
	assert s.routines[0].req.seq == 2
	assert !s.routines[0].accepted
	assert step(mut s, 256) == [u8(0x7F), 0x31, 0x22]
	assert !s.pending()
	// the same with a transport that never frees: given up P2*server_max after the deadline
	assert rcall(mut s, rq(0x01, rid_sync, [u8(0xFF)])) == pending_78
	fb.dispatch(mut s, 0, .running, 0, [])
	s.tick(t0 + 20_000_000)
	assert s.pending()
	s.tick(t0 + 20_000_000 + p2_star_server_us - 1)
	assert s.pending()
	assert rcall(mut s, [u8(0x3E), 0x00]).len == 0, 'still dropping'
	s.tick(t0 + 20_000_000 + p2_star_server_us)
	assert !s.pending(), 'abandoned'
	assert rcall(mut s, [u8(0x3E), 0x00]) == [u8(0x7E), 0x00]
}

// @verifies REQ-DIAG-083
// The final answer is sent even when the request set the suppress bit; 03, answered at once, honours
// it. A lost responsePending goes again at once; a final answer the transport cannot hold is 0x14.
fn test_suppression_lost_responses_and_capacity() {
	mut s := routine_server()
	mut fb := Fb{}
	assert rcall(mut s, rq(0x81, rid_sync, [u8(2)])) == pending_78
	fb.dispatch(mut s, 0, .done, 0, [u8(0), 4])
	assert step(mut s, 256) == [u8(0x71), 0x01, 0x02, 0x01, 0x02, 0x00, 0x04]
	assert rcall(mut s, rq(0x83, rid_sync, [])).len == 0
	assert rcall(mut s, rq(0x03, rid_sync, [])).len == 7
	// a lost responsePending: the next goes at once
	assert rcall(mut s, rq(0x01, rid_sync, [u8(2)])) == pending_78
	fb.dispatch(mut s, 0, .running, 0, [])
	s.tick(t0 + 1_000_000)
	assert step(mut s, 256).len == 0
	s.pending_lost()
	assert step(mut s, 256) == pending_78
	assert step(mut s, 256).len == 0
	// a final answer longer than the transport holds
	fb.dispatch(mut s, 0, .done, 0, [u8(0), 4])
	assert step(mut s, 6) == [u8(0x7F), 0x31, 0x14]
	// the 0x10 answer's timing is the server's P2 / P2* (50 ms, 5 s)
	assert rcall(mut s, [u8(0x10), 0x03]) == [u8(0x50), 0x03, 0x00, 0x32, 0x01, 0xF4]
}

// @verifies REQ-DIAG-084
// While an answer is owed every other request is dropped, unanswered and unperformed, functional
// ones included, and S3 does not run; once it is answered S3 runs again.
fn test_requests_are_dropped_and_s3_held_while_an_answer_is_owed() {
	mut s := routine_server()
	s.s3_us = 2_000_000
	mut fb := Fb{}
	s.tick(t0 + 100_000)
	assert rcall(mut s, rq(0x01, rid_sync, [u8(1)])) == pending_78
	for req in [[u8(0x10), 0x01], [u8(0x3E), 0x00], [u8(0x3E), 0x80], [u8(0x22), 0xF1, 0x90],
		rq(0x01, rid_sync, [u8(1)])] {
		assert rcall(mut s, req).len == 0, '${req}'
	}
	assert functional(mut s, [u8(0x3E), 0x80]).len == 0
	assert functional(mut s, [u8(0x10), 0x01]).len == 0
	assert s.session == session_extended
	assert s.routines[0].req.seq == 1, 'a dropped start reached the FB'
	fb.dispatch(mut s, 0, .running, 0, [])
	for t := u64(0); t <= 9_000_000; t += 1_000_000 {
		s.tick(t0 + 100_000 + t)
	}
	assert s.session == session_extended, 'S3 ran under an owed answer'
	fb.dispatch(mut s, 0, .done, 0, [])
	assert step(mut s, 256)[0] == 0x71
	s.tick(t0 + 100_000 + 9_000_000 + 2_000_001)
	assert s.session == session_default, 'S3 did not run again after the answer'
}

// @verifies REQ-DIAG-085
// Every session entry asks a running routine to stop — re-entering the session, S3, a reset — and
// an answer still owed is answered 0x22 (never abandoned by the server itself). A start after a
// server-issued stop not yet acknowledged reaches the FB.
fn test_a_routine_does_not_outlive_its_session() {
	mut s := routine_server()
	s.s3_us = 2_000_000
	unlock(mut s)
	mut fb := Fb{}
	assert rcall(mut s, rq(0x01, rid_async, [])) == pending_78
	fb.dispatch(mut s, 1, .running, 0, [])
	assert step(mut s, 256)[0] == 0x71
	// re-entry
	assert rcall(mut s, [u8(0x10), 0x03])[0] == 0x50
	assert s.routines[1].req.op == .stop
	stop_seq := s.routines[1].req.seq
	// the server does not wait for the FB: a start passes to it at once, after the stop
	unlock(mut s)
	assert rcall(mut s, rq(0x01, rid_async, [])) == pending_78
	assert s.routines[1].req.seq == stop_seq + 1 && s.routines[1].req.op == .start
	assert fb.dispatch(mut s, 1, .stopped, 0, []) == .stop
	assert fb.dispatch(mut s, 1, .running, 0, []) == .start
	assert step(mut s, 256)[0] == 0x71
	// S3
	s.tick(t0 + 3_000_000)
	assert s.session == session_default
	assert s.routines[1].req.op == .stop
	assert fb.dispatch(mut s, 1, .stopped, 0, []) == .stop
	// a reset, with a sync answer owed: 0x22 on the next step
	mut fs := Fb{}
	assert rcall(mut s, [u8(0x10), 0x03])[0] == 0x50
	assert rcall(mut s, rq(0x01, rid_sync, [u8(1)])) == pending_78
	assert fs.dispatch(mut s, 0, .running, 0, []) == .start
	s.reset_state()
	assert s.routines[0].req.op == .stop
	assert s.pending()
	assert step(mut s, 256) == [u8(0x7F), 0x31, 0x22]
	// an owed answer at a session entry by the owner (end_session): 0x22 as well
	assert rcall(mut s, [u8(0x10), 0x03])[0] == 0x50
	assert rcall(mut s, rq(0x01, rid_sync, [u8(1)])) == pending_78
	s.end_session()
	assert step(mut s, 256) == [u8(0x7F), 0x31, 0x22]
	// abandoned only when the owner says its transport is gone
	assert rcall(mut s, [u8(0x10), 0x03])[0] == 0x50
	assert rcall(mut s, rq(0x01, rid_sync, [u8(1)])) == pending_78
	s.pending_abandon()
	assert !s.pending()
	assert s.routines[0].req.op == .stop
	assert step(mut s, 256).len == 0
}

// The message lengths generation sizes with, pinned against the bytes; and each cell fits one IOC
// payload (IOC_MAX, 64 bytes: boards/common/ioc.h, osal/osal_native.c).
fn test_routine_message_lengths() {
	assert sizeof(RoutineRequest) <= 64 && sizeof(RoutineResult) <= 64
	assert routine_request_len(1) == rq(0x01, rid_sync, [u8(1)]).len
	assert routine_request_len(0) == 4
	mut s := routine_server()
	mut fb := Fb{}
	rcall(mut s, rq(0x01, rid_sync, [u8(1)]))
	fb.dispatch(mut s, 0, .done, 0, [])
	assert step(mut s, 256).len == routine_answer_len(2)
}

// requestRoutineResults whose answer the server's buffer cannot hold is refused responseTooLong
// even with the suppress bit set: suppression withholds a positive answer only (ISO 14229-1).
fn test_results_too_long_is_refused_under_suppression() {
	mut s := routine_server()
	mut fb := Fb{}
	assert rcall(mut s, rq(0x01, rid_sync, [u8(1)])) == pending_78
	fb.dispatch(mut s, 0, .done, 0, [u8(0), 4])
	assert step(mut s, 256)[0] == 0x71
	s.resp_cap = routine_answer_len(2) - 1 // one byte short of 03's answer
	assert rcall(mut s, rq(0x03, rid_sync, [])) == [u8(0x7F), 0x31, 0x14]
	assert rcall(mut s, rq(0x83, rid_sync, [])) == [u8(0x7F), 0x31, 0x14]
	s.resp_cap = 256
	assert rcall(mut s, rq(0x83, rid_sync, [])).len == 0
}

// @verifies REQ-DIAG-082 REQ-DIAG-084
// A result in its cell when the timeout is judged is the answer, not 0x22: the owner reads the
// result cells before tick, so a report the FB published before the deadline counts even when the
// transport takes the answer only after it. If it never does, the answer is given up P2*server_max
// later and its FB asked to stop, as when the transport is gone — an asynchronous start already
// reported running included; a session entry in that window answers 0x22 within the same bound.
// A result that comes after the deadline is too late.
fn test_a_result_in_its_cell_at_the_timeout_is_the_answer() {
	mut s := routine_server()
	mut fb := Fb{}
	assert rcall(mut s, rq(0x01, rid_sync, [u8(1)])) == pending_78
	fb.dispatch(mut s, 0, .running, 0, [])
	s.tick(t0 + 10_000_000 - 1)
	fb.dispatch(mut s, 0, .done, 0, [u8(0), 7]) // read into the server in the deadline's pass
	s.tick(t0 + 10_000_000)
	assert s.routines[0].req.op == .start, 'a completed routine is not asked to stop'
	assert step(mut s, 256) == [u8(0x71), 0x01, 0x02, 0x01, routine_info_done, 0x00, 7]
	assert s.routines[0].accepted
	// ready at the deadline, the transport never free: abandoned P2*server_max later
	assert rcall(mut s, rq(0x01, rid_sync, [u8(1)])) == pending_78
	fb.dispatch(mut s, 0, .done, 0, [u8(0), 8])
	s.tick(t0 + 20_000_000)
	assert s.pending() && s.routines[0].req.op == .start
	s.tick(t0 + 20_000_000 + p2_star_server_us - 1)
	assert s.pending()
	s.tick(t0 + 20_000_000 + p2_star_server_us)
	assert !s.pending(), 'abandoned'
	assert s.routines[0].req.op == .stop, 'an answer nobody got: its FB asked to stop'
	assert !s.routines[0].accepted
	fb.dispatch(mut s, 0, .stopped, 0, [])
	// a result read only after the deadline was judged: 0x22
	assert rcall(mut s, rq(0x01, rid_sync, [u8(1)])) == pending_78
	fb.dispatch(mut s, 0, .running, 0, [])
	s.tick(t0 + 40_000_000)
	fb.dispatch(mut s, 0, .done, 0, [u8(0), 9])
	assert step(mut s, 256) == [u8(0x7F), 0x31, 0x22]
	// an asynchronous start the FB reported running before the deadline: ready, then abandoned
	// the same way, the routine not left running unanswered
	unlock(mut s)
	mut fa := Fb{}
	assert rcall(mut s, rq(0x01, rid_async, [])) == pending_78
	fa.dispatch(mut s, 1, .running, 0, [])
	s.tick(t0 + 50_000_000)
	assert s.pending() && s.routines[1].req.op == .start
	s.tick(t0 + 50_000_000 + p2_star_server_us)
	assert !s.pending()
	assert s.routines[1].req.op == .stop && !s.routines[1].accepted
	// a session entry while a ready answer waits past its deadline: 0x22, given up when the wait
	// was to end — never P2*server_max after the session entry
	assert rcall(mut s, rq(0x01, rid_sync, [u8(1)])) == pending_78
	fb.dispatch(mut s, 0, .done, 0, [u8(0), 8])
	s.tick(t0 + 65_000_000)
	assert s.pending()
	s.tick(t0 + 69_000_000)
	s.end_session()
	assert s.pending() && s.routines[0].req.op == .stop
	s.tick(t0 + 65_000_000 + p2_star_server_us)
	assert !s.pending(), 'the bound did not grow'
}

// A Routine is plain data its owner fills: one configured with a record its cells cannot hold
// (past max_routine_record) is never served — an answer would read past the result cell, a start
// would drop the option bytes past it — so its identifier is answered as not configured (0x31).
fn test_a_routine_whose_records_overflow_its_cells_is_not_served() {
	big := u8(max_routine_record + 1)
	mut s := routine_server()
	s.routines[0].start_out = big
	assert rcall(mut s, rq(0x01, rid_sync, [u8(1)])) == [u8(0x7F), 0x31, 0x31]
	assert !s.pending()
	s = routine_server()
	s.routines[0].results_out = big
	assert rcall(mut s, rq(0x03, rid_sync, [])) == [u8(0x7F), 0x31, 0x31]
	assert rcall(mut s, rq(0x01, rid_sync, [u8(1)])) == [u8(0x7F), 0x31, 0x31]
	s = routine_server()
	s.routines[0].start_in = big
	mut option := []u8{len: int(big), init: u8(index + 1)}
	assert rcall(mut s, rq(0x01, rid_sync, option)) == [u8(0x7F), 0x31, 0x31]
	assert s.routines[0].req.seq == 0, 'nothing written into the request cell'
	// at the cells' size, served
	s = routine_server()
	s.routines[0].start_in = u8(max_routine_record)
	s.routines[0].start_out = u8(max_routine_record)
	s.routines[0].results_out = u8(max_routine_record)
	option = []u8{len: max_routine_record, init: u8(index + 1)}
	assert rcall(mut s, rq(0x01, rid_sync, option)) == pending_78
	assert s.routines[0].req.data[max_routine_record - 1] == u8(max_routine_record)
}

// @verifies REQ-DIAG-081
// An FB that stopped running after taking a request: every start then times out and asks it to
// stop, each a request it never sees. Before its last report falls half the sequence range behind
// — where RoutineFb.take would judge the stop it has not taken older than a start after it — starts
// are refused (0x22), so when the FB runs again the stop reaches it first; once it reports, a start
// is served again.
fn test_a_start_is_refused_while_its_fb_lags_behind() {
	mut s := routine_server()
	mut fb := Fb{}
	mut now := t0
	assert rcall(mut s, rq(0x01, rid_sync, [u8(1)])) == pending_78
	assert fb.dispatch(mut s, 0, .running, 0, []) == .start
	mut refused := false
	for _ in 0 .. 0x4000 {
		now += 10_000_000
		s.tick(now)
		assert step(mut s, 256) == [u8(0x7F), 0x31, 0x22]
		a := rcall(mut s, rq(0x01, rid_sync, [u8(1)]))
		if a == [u8(0x7F), 0x31, 0x22] {
			refused = true
			break
		}
		assert a == pending_78
	}
	assert refused, 'a start served with the FB 0x8000 requests behind'
	assert u16(s.routines[0].req.seq - s.routines[0].res.seq) < routine_seq_window + 2
	assert fb.dispatch(mut s, 0, .stopped, 0, []) == .stop, 'the stop the FB has not taken comes first'
	assert rcall(mut s, rq(0x01, rid_sync, [u8(1)])) == pending_78
	assert fb.dispatch(mut s, 0, .done, 0, [u8(0), 3]) == .start
	assert step(mut s, 256)[4] == routine_info_done
}
