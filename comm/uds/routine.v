module uds

// RoutineControl (0x31) in an application server (docs/diagnostics.md §3.1 "Routines"). A routine
// is RUN BY AN FB, on that FB's thread, never by the server: the server and the FB's glue exchange
// two cells per routine — the REQUEST cell the server writes (a sequence number, the operation, the
// option record, and a stop the FB has not been seen to take) and the RESULT cell the FB's glue
// writes (the request it answers, the routine's state, an NRC for a refusal, the result record).
// The generated code carries each across threads (a byte IOC on a ThreadX target, a triple channel
// on the host bridge), so each holds only its LATEST value; the server only reads `res` and writes
// `req`. A start or stop is answered responsePending (0x78) in the pass that serves it and finally
// when the FB has reported (pending.v).

pub const max_routines = 4
pub const max_routine_record = 32 // the most an option or result record carries (max_did_data's)

// default_routine_timeout_us: a start or stop not answered by its FB within this is answered
// conditionsNotCorrect (0x22) and the FB asked to stop (Routine.timeout_us 0 = this)
pub const default_routine_timeout_us = u64(10_000_000)

// routine_seq_window: how many requests an FB's last report may fall behind before a start is
// refused (Routine.lagging) — far inside the half range RoutineFb.take orders requests by (a few
// requests at most are written past it: the stops a session entry or a timeout asks), and far
// beyond any working FB, which reports on every request it takes
pub const routine_seq_window = u16(0x1000)

// routineInfo, the byte after the identifier in every positive 0x31 answer (manufacturer-specific
// in ISO 14229-1; these are blobly's): the state the FB last reported
pub const routine_info_running = u8(1)
pub const routine_info_done = u8(2)
pub const routine_info_stopped = u8(3)
pub const routine_info_failed = u8(4)

// RoutineOp: what the server asks of the FB. none = nothing new (a sequence number already seen).
pub enum RoutineOp as u8 {
	none
	start
	stop
}

// RoutineState: what the FB reports. none = nothing new this dispatch (the last report stands);
// refused = the FB will not do the request it was handed, answered with its `nrc` — a refusal is no
// state of the routine: it leaves the state (and the record) it had, so a stop refused leaves the
// routine running. failed = the routine ENDED in failure, whatever the request.
pub enum RoutineState as u8 {
	none
	running
	done
	stopped
	failed
	refused
}

// RoutineRequest is the request cell (the server writes, the FB's glue reads). seq 0 = never asked.
// `stop` keeps a stop the FB has not been seen to take (its sequence number; 0 = none) when a start
// is written after it — the cell holds only its latest value, and a stop the server issued itself
// (a session entry, a timeout) must reach the FB before the start that follows it (RoutineFb.take).
pub struct RoutineRequest {
pub mut:
	seq  u16
	op   RoutineOp
	stop u16
	data [max_routine_record]u8 // the start's option record (its first start_in bytes)
}

// RoutineResult is the result cell (the FB's glue writes, the server reads): stamped with the
// request it answers last. `state` is the routine's state as the FB last reported it (never
// refused: none until the FB reports one) and `data` its record, both standing until the FB reports
// another state; `nrc`, when not 0, is the FB's refusal of request `seq` (RoutineFb.report).
pub struct RoutineResult {
pub mut:
	seq   u16
	state RoutineState
	nrc   u8
	data  [max_routine_record]u8 // the result record: start_out bytes for 01, results_out for 03
}

// Routine is one configured [[routine]] with its two cells. No field defaults (the _vinit rule):
// the owner fills the configuration; zero cells are "nothing asked, nothing reported".
pub struct Routine {
pub mut:
	id          u16
	sessions    u8 // in_* mask; 0 = every session
	security    u8 // the 0x27 level a request needs; 0 = none
	async       bool // 01 answers once the FB has accepted it (running), not when it completes
	stop        bool // 02 offered
	results     bool // 03 offered
	start_in    u8 // option record bytes a start carries (exactly)
	start_out   u8 // record bytes a start's answer carries
	results_out u8 // record bytes a 03 answer carries
	timeout_us  u64 // 0 = default_routine_timeout_us
	req         RoutineRequest
	res         RoutineResult
	// the latest start was answered positively (cleared by a new start until it is answered, and
	// by reset_state): only then is 03 served
	accepted bool
}

// routine_request_len: a 0x31 request carrying an option record of `n` bytes (the service, the
// sub-function, the identifier, the record) — and the length a 02 / 03 request has (n = 0).
pub fn routine_request_len(n int) int {
	return 4 + n
}

// routine_answer_len: a positive 0x31 answer carrying a record of `n` bytes (the service, the
// sub-function, the identifier, routineInfo, the record).
pub fn routine_answer_len(n int) int {
	return 5 + n
}

// fresh: the FB has reported on the LATEST request — a state, or a refusal (a stale result,
// stamped with an earlier one, is ignored)
fn (r &Routine) fresh() bool {
	return r.req.seq != 0 && r.res.seq == r.req.seq && (r.res.state != .none || r.res.nrc != 0)
}

// refused: the FB refused the latest request
fn (r &Routine) refused() bool {
	return r.fresh() && r.res.nrc != 0
}

// running: since the latest request the FB reports the routine running — including a stop it
// refused, which leaves it running. A routine the server has asked to stop and whose FB has not
// answered yet is NOT running to a tester: a start then reaches the FB after that stop (take).
fn (r &Routine) running() bool {
	return r.fresh() && r.res.state == .running
}

// may_run: the FB may still be running it — its last report says so (a refused stop included), or
// a start it has not answered yet
fn (r &Routine) may_run() bool {
	return r.res.state == .running || (r.req.op == .start && r.res.seq != r.req.seq)
}

// sizes_ok: every record size the routine is configured with fits its cells (max_routine_record).
// A Routine is plain data its owner fills, so the server holds it to this itself: one that does not
// fit is never served (find_routine), so no answer reads past the result cell and no start drops
// an option byte the request carried.
fn (r &Routine) sizes_ok() bool {
	return r.start_in <= max_routine_record && r.start_out <= max_routine_record
		&& r.results_out <= max_routine_record
}

// lagging: the FB's last report is routine_seq_window or more requests behind the latest — it has
// not run for that many requests (each one a start whose timeout ran out, or a stop). A start is
// then refused (0x22) until it reports again, so the sequence numbers never get half their range
// ahead of the FB, where RoutineFb.take would judge a stop it has not taken older than the start
// after it (seq_after). The FB must answer the stop it takes first when it resumes (the contract's
// "answer every op"): ignored, that stop leaves res.seq as far behind and no request reaches it again.
fn (r &Routine) lagging() bool {
	return u16(r.req.seq - r.res.seq) >= routine_seq_window
}

fn (r &Routine) timeout() u64 {
	return if r.timeout_us == 0 { default_routine_timeout_us } else { r.timeout_us }
}

// ask: a new request into the routine's request cell, under a fresh sequence number (never 0, the
// "never asked" value). A stop is kept in `stop` until the FB is seen to have taken it: an answer on
// the latest request (it takes requests in order) clears it, so `stop` is only ever the latest
// request or the one before it, and a later start cannot hide it from the FB.
fn (mut r Routine) ask(op RoutineOp, data &u8, n int) {
	if r.res.seq == r.req.seq {
		r.req.stop = 0 // the FB answered the latest request, so it has taken every one
	}
	r.req.seq = if r.req.seq == 0xFFFF { u16(1) } else { r.req.seq + 1 }
	r.req.op = op
	if op == .stop {
		r.req.stop = r.req.seq
	}
	for i in 0 .. max_routine_record {
		r.req.data[i] = if i < n { unsafe { data[i] } } else { u8(0) }
	}
}

// ask_stop: the server asks routine i's FB to stop (a session entry, a timeout, a dropped
// connection) — unless the latest request is already a stop the FB has not refused (it is carrying
// it out, or has not taken it yet). A start the FB has not taken yet is then never handed over: the
// stop is, in its place.
fn (mut s Server) ask_stop(i int) {
	mut r := &s.routines[i]
	if r.req.op == .stop && !r.refused() {
		return
	}
	r.ask(.stop, unsafe { nil }, 0)
}

// stop_routines: a session entry (enter_session, reset_state) asks every routine its FB may still
// be running to stop — a routine gated to a session does not outlive it — and an answer still owed
// is answered conditionsNotCorrect (fail_owed), on the transport that asked. The server does not
// wait for any stop to be acknowledged.
fn (mut s Server) stop_routines() {
	for i in 0 .. s.nroutines {
		if i >= max_routines {
			break
		}
		if s.routines[i].may_run() {
			s.ask_stop(i)
		}
	}
	if s.pend_sid != 0 && !s.pend_fail {
		s.fail_owed()
	}
}

// stop_relocked_routines: end_levels' share for the routines (io_control.v) — every routine gated on
// a level the relock ends (relock_ends: `level`, or every level but `level` when `others`) that its
// FB may still be running is asked to stop, as the controls are returned. A routine's `security` is
// its EFFECTIVE level, its own else its 0x31 service row's (generation, gen_routine.v routine_gate),
// so a routine gated through the row is stopped too. No answer can be owed for such a routine: a key
// is dropped while an answer is owed, and the network tester whose unlock ends had its own owed
// answer abandoned first (comm/diag remote_dropped).
fn (mut s Server) stop_relocked_routines(level u8, others bool) {
	for i in 0 .. s.nroutines {
		if i >= max_routines {
			break
		}
		if relock_ends(s.routines[i].security, level, others) && s.routines[i].may_run() {
			s.ask_stop(i)
		}
	}
}

// find_routine: the routine of identifier `id` the server serves (-1 = none) — one whose record
// sizes do not fit its cells is none (sizes_ok)
fn (s &Server) find_routine(id u16) int {
	for i in 0 .. s.nroutines {
		if i >= max_routines {
			break
		}
		if s.routines[i].id == id && s.routines[i].sizes_ok() {
			return i
		}
	}
	return -1
}

// routine_control (0x31): startRoutine (01), stopRoutine (02) where offered, requestRoutineResults
// (03) where offered. After the service row's checks (dispatch), in ISO 14229-1's order: the
// general checks of a request with a sub-function — length < 2 (0x13), a sub-function other than
// 01/02/03 (0x12) — then 0x31's own: length < 4 (0x13); an identifier not configured (or configured
// with records its cells cannot hold, find_routine) or not in the active session (0x31); the
// routine's level (0x33); a sub-function the routine does not offer (0x12); the exact length
// (0x13); the sequence (0x24): a start while the FB reports it running, a stop while it does not,
// results with no start answered positively; a start while its FB lags (0x22, lagging). A start or
// stop is then
// written into the routine's request cell and answered responsePending (0x78) — whatever the
// suppress bit, since its answer is owed (pending.v); 03 answers at once from the FB's latest report.
fn (mut s Server) routine_control(req &u8, req_len int, resp &u8) int {
	if req_len < 2 {
		return negative(resp, 0x31, nrc_incorrect_length)
	}
	sub := unsafe { req[1] } & 0x7F
	if sub < 0x01 || sub > 0x03 {
		return negative(resp, 0x31, nrc_subfunction_not_supported)
	}
	if req_len < 4 {
		return negative(resp, 0x31, nrc_incorrect_length)
	}
	id := unsafe { (u16(req[2]) << 8) | u16(req[3]) }
	i := s.find_routine(id)
	if i < 0 || !in_mask(s.routines[i].sessions, s.session) {
		return negative(resp, 0x31, nrc_request_out_of_range)
	}
	mut r := &s.routines[i]
	if r.security != 0 && s.unlocked != r.security {
		return negative(resp, 0x31, nrc_security_access_denied)
	}
	if (sub == 0x02 && !r.stop) || (sub == 0x03 && !r.results) {
		return negative(resp, 0x31, nrc_subfunction_not_supported)
	}
	want := routine_request_len(if sub == 0x01 { int(r.start_in) } else { 0 })
	if req_len != want {
		return negative(resp, 0x31, nrc_incorrect_length)
	}
	match sub {
		0x01 {
			if r.running() {
				return negative(resp, 0x31, nrc_request_sequence_error)
			}
			if r.lagging() {
				return negative(resp, 0x31, nrc_conditions_not_correct)
			}
			r.accepted = false
			r.ask(.start, unsafe { req + 4 }, int(r.start_in))
			return s.go_pending(0x31, i, sub, r.timeout(), resp)
		}
		0x02 {
			if !r.running() {
				return negative(resp, 0x31, nrc_request_sequence_error)
			}
			r.ask(.stop, unsafe { nil }, 0)
			return s.go_pending(0x31, i, sub, r.timeout(), resp)
		}
		else {
			if !r.accepted {
				return negative(resp, 0x31, nrc_request_sequence_error)
			}
			n := routine_answer_len(int(r.results_out))
			if n > s.cap() {
				return negative(resp, 0x31, nrc_response_too_long)
			}
			if unsafe { req[1] } & 0x80 != 0 {
				return 0 // answered at once, so the suppress bit is honoured — a positive answer only
			}
			return routine_answer(resp, 0x03, r, int(r.results_out))
		}
	}
}

// routine_owed: the owed start or stop of routine pend_idx answered once its FB has reported on it
// (0 = not yet). A refusal is answered with the FB's NRC (routine_refusal_nrc); otherwise a
// synchronous start waits until it is no longer running, a stop likewise, and an asynchronous start
// is answered at the first report.
fn (mut s Server) routine_owed(resp &u8, cap int) int {
	if !s.routine_ready() {
		return 0
	}
	mut r := &s.routines[s.pend_idx]
	if r.res.nrc != 0 {
		return negative(resp, 0x31, routine_refusal_nrc(r.res.nrc))
	}
	n := if s.pend_sub == 0x01 { int(r.start_out) } else { 0 }
	if routine_answer_len(n) > cap {
		return negative(resp, 0x31, nrc_response_too_long)
	}
	if s.pend_sub == 0x01 {
		r.accepted = true
	}
	return routine_answer(resp, s.pend_sub, r, n)
}

// routine_ready: the FB has reported on the owed start or stop of routine pend_idx so that it is
// answered (routine_owed's rule): a refusal, a synchronous start or a stop no longer running, an
// asynchronous start in any state
fn (s &Server) routine_ready() bool {
	r := &s.routines[s.pend_idx]
	if !r.fresh() {
		return false
	}
	return r.res.nrc != 0 || r.res.state != .running || (s.pend_sub == 0x01 && r.async)
}

// routine_refusal_nrc: the NRC an FB's refusal is answered with — the ones a routine may give
// (conditionsNotCorrect, requestSequenceError, requestOutOfRange, generalProgrammingFailure), any
// other as conditionsNotCorrect: an FB never answers responsePending, nor a service-level NRC.
pub fn routine_refusal_nrc(nrc u8) u8 {
	return match nrc {
		nrc_conditions_not_correct, nrc_request_sequence_error, nrc_request_out_of_range,
		nrc_general_programming_failure {
			nrc
		}
		else {
			nrc_conditions_not_correct
		}
	}
}

// routine_info: routineInfo for the state the FB reported
fn routine_info(st RoutineState) u8 {
	return match st {
		.running { routine_info_running }
		.done { routine_info_done }
		.stopped { routine_info_stopped }
		else { routine_info_failed }
	}
}

// routine_answer: 71 sub RID routineInfo, then the first n bytes of the FB's record
fn routine_answer(resp &u8, sub u8, r &Routine, n int) int {
	unsafe {
		resp[0] = 0x71
		resp[1] = sub
		resp[2] = u8(r.id >> 8)
		resp[3] = u8(r.id)
		resp[4] = routine_info(r.res.state)
		for k in 0 .. n {
			resp[5 + k] = r.res.data[k]
		}
	}
	return routine_answer_len(n)
}

// RoutineFb is the FB side of a routine, held in its thread's state by the generated glue: it owns
// the sequence numbers, so the FB itself sees only operations. take() hands each operation over in
// exactly one dispatch, in the order the server wrote them; report() stamps what the FB wrote with
// the request it answers. The state stands until the FB reports another — a dispatch that writes
// none (state .none) changes nothing, nor does a refusal — so the glue copies the FB's record only
// when report() returns true.
pub struct RoutineFb {
pub mut:
	seen u16 // the latest request taken
	res  RoutineResult
}

// take: the operation of a request not taken before — a stop the server wrote before the latest
// request first, in a dispatch of its own (the start after it comes in the next); seq 0, nothing
// ever asked, is none. Stops written before the FB took the first are one stop to it, and a start
// the server stopped before the FB took it is never handed over (the stop is, in its place). The
// server does not wait for a stop it issued to be acknowledged, so that next dispatch's start can
// come while the FB is still stopping (a stop that takes it several dispatches): the FB refuses it
// (.refused, 0x24) until it has stopped.
pub fn (mut f RoutineFb) take(req &RoutineRequest) RoutineOp {
	if req.stop != 0 && seq_after(req.stop, f.seen) {
		f.seen = req.stop
		return .stop
	}
	if req.seq == 0 || req.seq == f.seen {
		return .none
	}
	f.seen = req.seq
	return req.op
}

// seq_after: sequence number a comes after b (they wrap; the server keeps the latest within
// routine_seq_window and a few of the FB's last report, Routine.lagging)
fn seq_after(a u16, b u16) bool {
	return a != b && u16(a - b) < 0x8000
}

// report: the FB's state this dispatch, stamped with the request taken last — true when it wrote a
// state, so the glue copies its record. A refusal (.refused) stamps the request with the FB's NRC
// (one a routine may give, routine_refusal_nrc) and changes neither the state nor the record, and
// returns false; so do none and a report before any request was taken. A refusal is that request's
// answer: a state reported after it for the same request (a refused stop's running progress)
// leaves it standing, so a dispatch the server did not see between them cannot lose it; the next
// request's first report clears it.
pub fn (mut f RoutineFb) report(state RoutineState, nrc u8) bool {
	if state == .none || f.seen == 0 {
		return false
	}
	if f.res.seq != f.seen {
		f.res.nrc = 0 // a new request: an earlier one's refusal is not its answer
	}
	f.res.seq = f.seen
	if state == .refused {
		f.res.nrc = routine_refusal_nrc(nrc)
		return false
	}
	f.res.state = state
	return true
}
