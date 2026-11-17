module uds

// UDS (ISO 14229-1) server, no-alloc and transport-agnostic. It sits above ISO-TP (or DoIP):
// the owner hands it a reassembled request and ships the response it produces. Table-driven so
// the protocol logic is shared and unit-tested; the DIDs (and any live-signal refresh) are
// filled in by the generated bridge (docs/diagnostics.md §3.1).
//
// Services: 0x10 DiagnosticSessionControl, 0x11 ECUReset, 0x22 ReadDataByIdentifier (several
// DIDs per request), 0x27 SecurityAccess (with injected SecurityOps) — or, on a node that unlocks
// by Authentication instead, 0x29 (ACR with Ed25519, injected AuthOps; auth.v) — 0x28 CommunicationControl,
// 0x14 / 0x19 / 0x85 over an injected FaultOps (comm/fault),
// 0x2E WriteDataByIdentifier (a BOUND DID — a parameter — through the injected DidWrite, comm/param),
// 0x2F InputOutputControlByIdentifier (a live signal's DID with a control, io_control.v),
// 0x31 RoutineControl (each configured routine run by an FB through two cells, routine.v),
// 0x3E TesterPresent. Anything else -> 0x11 serviceNotSupported.
// A routine's start or stop is answered responsePending (0x78) until its FB has reported, every
// other request dropped meanwhile (pending.v).
// An application server's 0x10 02 is the programming HANDOFF (boot_handoff): answered, then
// performed by the owner as a reset into the bootloader (reset_into_boot).
// Which of those a node answers, where, and behind which 0x27 level is the SERVICE TABLE
// (Server.services, configured from [uds] `services`); an empty table is the default set.
//
// Negative responses follow ISO 14229-1's evaluation order. Every service: supported and in the
// table (0x11) → allowed in the active session (0x7F) → the table's security level (0x33) →
// minimum length (0x13); then, for a subfunction service:
// subfunction supported (0x12) → exact length (0x13) → conditions / range. The DID services follow
// their own flow: 0x22 — length, then each DID's support and session (0x31 when none answers),
// then security (0x33), then the response size (0x14); 0x2E — length, then the DID's support,
// writability and session (0x31), then security (0x33), then the record length (0x13); 0x2F — its
// own order (io_control.v). 0x31 —
// length < 2 (0x13), subfunction (0x12), length < 4 (0x13), the routine's identifier and session
// (0x31), its level (0x33), a subfunction it does not offer (0x12), the exact length (0x13), the
// sequence (0x24), then its FB's own refusal. 0x27 —
// subfunction (0x12), then requestSeed: the lockout delay (0x37); sendKey: length (0x13), a seed
// of that level outstanding (0x24), the lockout delay (0x37: the seed spent, the key not judged —
// a seed drawn over the other transport before the lockout buys no key during it), the key (0x35,
// or 0x36 on the last allowed attempt). A
// FUNCTIONAL request never answers 0x11, 0x12, 0x31, 0x7E or 0x7F (handle_functional) — a broadcast
// into an unsupported or gated service stays silent — and a functional 0x27, 0x29, 0x2F or 0x31 is
// ignored outright. 0x29's own order is in auth.v.

pub const max_dids = 16
pub const max_did_data = 32 // bytes stored per DID

// The smallest response buffer init() accepts: the longest FIXED response (0x50 with its P2/P2*
// timing, 6 bytes). A smaller buffer could not hold even that, so the server refuses to run at all
// rather than write past it.
pub const min_resp_cap = 6

// The response capacity a caller that never called init() gets: the longest response the
// single-DID server could produce (3 + max_did_data), so every pre-existing caller's buffer
// (the generated bridge's 64 B; comm/doip reserves exactly this for an embedded server) stays within bounds.
pub const legacy_resp_cap = 3 + max_did_data

// Sessions, as the 0x10 subfunction values.
pub const session_default = u8(0x01)
pub const session_programming = u8(0x02)
pub const session_extended = u8(0x03)
pub const session_safety = u8(0x04)

// A session MASK names the sessions something is allowed in, one bit per session value
// (bit n-1 for session n). 0 means "every session" — the unconfigured default, which is also
// what a zeroed struct holds on a target that never runs _vinit.
pub const in_default = u8(0x01)
pub const in_programming = u8(0x02)
pub const in_extended = u8(0x04)
pub const in_safety = u8(0x08)

// Default S3 (session timeout) when none is configured: 5 s, ISO 14229-2's S3_server.
pub const default_s3_us = u64(5_000_000)

// negative-response codes (NRC)
pub const nrc_service_not_supported = u8(0x11)
pub const nrc_subfunction_not_supported = u8(0x12)
pub const nrc_incorrect_length = u8(0x13)
pub const nrc_response_too_long = u8(0x14)
pub const nrc_conditions_not_correct = u8(0x22)
pub const nrc_request_sequence_error = u8(0x24)
pub const nrc_request_out_of_range = u8(0x31)
pub const nrc_security_access_denied = u8(0x33)
pub const nrc_invalid_key = u8(0x35)
pub const nrc_exceeded_attempts = u8(0x36)
pub const nrc_time_delay_not_expired = u8(0x37)
pub const nrc_general_programming_failure = u8(0x72)
pub const nrc_response_pending = u8(0x78)
pub const nrc_subfunction_not_in_session = u8(0x7E)
pub const nrc_service_not_in_session = u8(0x7F)

// SecurityAccess (0x27). Level L is requested with subfunction 2L-1 (requestSeed) and unlocked
// with 2L (sendKey); a DID's `security` gate names L.
pub const seed_len = 4
pub const max_security_level = 8
pub const default_sa_attempts = u8(3)
pub const default_sa_delay_us = u64(10_000_000)

// SecurityOps is the 0x27 seam (docs/diagnostics.md §3.1, decision D5): where a seed comes from
// and whether a key is right for it. Function pointers, the shape boot.Prog.rng already uses, so
// comm/uds carries no C and no key: an OEM algorithm (or an HSM) lives in the board glue below
// the backend line. Nil `seed` or `key_ok` = 0x27 is not supported. `key_ok` compares; an
// implementation holding a real secret should compare in constant time.
pub struct SecurityOps {
pub mut:
	ctx    voidptr
	seed   fn (ctx voidptr, out &u8, n int) bool = unsafe { nil }
	key_ok fn (ctx voidptr, level u8, seed &u8, key &u8, n int) bool = unsafe { nil }
}

// FaultOps is the fault-memory seam 0x19 / 0x14 / 0x85 are answered through (comm/fault builds
// it; docs/diagnostics.md §3.3). Nil `entry` = 0x19 and 0x14 are not supported; nil `set_setting`
// = 0x85 is not; nil `snapshot` / `extended` = 0x19 03/04 / 06 are not. `entry(i)` returns DTC
// (3 bytes) << 8 | status for i in 0 .. count(). `snapshot(i, out, cap)` copies DTC i's snapshot
// record 0x01 body (out nil = only its length; 0 = none stored, -1 = larger than cap);
// `extended(i, rec, out, cap)` writes extended data record `rec` (1 .. ext_records) into out, at most
// `cap` bytes, and returns its length (0 = no such record, -1 = longer than cap).
pub struct FaultOps {
pub mut:
	ctx         voidptr
	count       fn (ctx voidptr) int = unsafe { nil }
	entry       fn (ctx voidptr, i int) u32 = unsafe { nil }
	clear       fn (ctx voidptr, group u32) u8 = unsafe { nil } // the NRC, 0 = cleared
	set_setting fn (ctx voidptr, on bool) = unsafe { nil }
	snapshot    fn (ctx voidptr, i int, out &u8, cap int) int = unsafe { nil }
	extended    fn (ctx voidptr, i int, rec u8, out &u8, cap int) int = unsafe { nil }
	ext_records u8 // extended data records 0x01 .. ext_records
	avail       u8 // the status availability mask; 0 = not wired (the services stay unsupported)
}

// DidWrite is the seam a bound DID's 0x2E goes through, after the server's session and security
// gates and its record-length check (the DID's declared size, 0x13): `write` returns the NRC (0 =
// accepted — the server then stores the record as the DID's data and answers). comm/param builds
// it: range (0x31), then the journal (0x72).
pub struct DidWrite {
pub mut:
	ctx   voidptr
	write fn (ctx voidptr, id u16, data &u8, n int) u8 = unsafe { nil }
}

// The service table (Server.services): which services the server answers, in which sessions, and
// behind which 0x27 level — AUTOSAR Dcm's service table, configured from [uds] `services`.
pub const max_services = 16

// Service is one row of the table. `sessions` is an in_* mask, 0 = the service's own default
// (default_sessions); `security` is the 0x27 level the service needs, 0 = none. A row grants
// nothing the owner has not wired: a service the server cannot perform (service_supported) still
// answers serviceNotSupported, whatever the table says.
pub struct Service {
pub mut:
	sid      u8
	sessions u8
	security u8
}

// SubService is one sub-function row (Server.subs): `sessions` is an in_* mask (0 = wherever its
// service runs), `security` the 0x27 level it needs (0 = none).
pub const max_sub_services = 4

pub struct SubService {
pub mut:
	sid      u8
	sub      u8
	sessions u8
	security u8
}

// reset_into_boot is the reset_req kind of the programming handoff: not an ECUReset sub-function
// (those are seven bits wide), so no 0x11 request can ever store it. The owner performs it like
// any answered reset, with the boot request cell written first.
pub const reset_into_boot = u8(0x80)

// Did is one Data Identifier: constant bytes, a RAM cell (writable), and/or kept fresh from a
// live signal by the bridge. Access is gated per DID: the session masks (0 = every session) and
// the security level a write needs (0 = none). A BOUND writable DID is a parameter's (comm/param):
// its 0x2E goes through Server.did_write, which validates and makes it durable first. A writable
// DID's `len` is its declared size: 0x2E accepts a record of exactly that length (0x13 otherwise).
pub struct Did {
pub mut:
	id             u16
	data           [max_did_data]u8
	len            u8
	writable       bool
	bound          bool
	read_sessions  u8
	write_sessions u8
	read_security  u8
	write_security u8
}

pub struct Server {
pub mut:
	// Current diagnostic session. No field defaults anywhere here (the _vinit rule): init()
	// sets the default session; a Server that was never initialised reads 0, which no service
	// matches as a session — fail-closed. The bootloader sets it directly (boot.Prog.init).
	session u8
	dids    [max_dids]Did
	ndid    int
	// The security level currently unlocked (0 = locked). Set by 0x27 or 0x29 (whichever the node
	// unlocks with); relocked on every session transition.
	unlocked u8
	// Response capacity of the caller's buffer (init); 0 = legacy_resp_cap.
	resp_cap int
	// S3: the owner calls tick(now) each pass; a request stamps last_rx_us.
	now_us     u64
	last_rx_us u64
	rx_seen    bool // last_rx_us holds a real request time (0 is a valid clock value)
	s3_us      u64 // 0 = default_s3_us
	// ECUReset requested (the 0x11 subfunction), or the programming handoff (reset_into_boot), for
	// the owner to perform once the response has left; 0 = none.
	reset_req u8
	// CommunicationControl (0x28) state for NORMAL communication messages, and whether this
	// server's node has a single network (so "all networks" and "this network" are the same).
	normal_tx_off  bool
	normal_rx_off  bool
	single_network bool
	// ECUReset and CommunicationControl only mean something where the OWNER acts on them — it
	// performs reset_req and gates its frames on tx_enabled/rx_enabled. An owner opts in; one that
	// does not (DoIP today; the bootloader serves 0x11 itself) keeps answering serviceNotSupported
	// rather than acknowledge a reset or a silence that never happens.
	serves_reset        bool
	serves_comm_control bool
	// An APPLICATION server has no erase/download services: those live in the bootloader
	// (boot.Prog). It never ENTERS the programming session: without `boot_handoff` it refuses
	// 0x10 02 (subFunctionNotSupported); with it, an accepted 0x10 02 is answered and recorded as
	// reset_req = reset_into_boot, for the owner to perform — write the boot request cell and
	// reset once the answer has left — so the bootloader's server opens the session. The
	// bootloader leaves both false: it enters programming itself.
	no_programming bool
	boot_handoff   bool
	// handoff_ok is the application's conditions seam for the handoff (REQ-BOOT-015): false
	// answers conditionsNotCorrect (0x22) and nothing is handed off. nil = allowed — the server
	// knows no vehicle state, and only the application can.
	handoff_ok fn () bool = unsafe { nil }
	// handoff_elsewhere: this request arrived over a transport the bootloader does not serve, so
	// the handoff is refused with conditionsNotCorrect (0x22): a handoff over DoIP to a bootloader
	// that answers on CAN only would reset the ECU out from under a tester whose TCP connection
	// dies with it, and leave it nothing to reconnect to. comm/diag sets it while serving a remote
	// request (unless Connection.handoff_remote). False is the zero value, on purpose: a
	// freestanding image never runs a field default.
	handoff_elsewhere bool
	// Sub-function rows: a service's sub-function gated beyond its service row (AUTOSAR's
	// sub-service table) — the sessions it is accepted from (0x7E otherwise) and the 0x27 level it
	// needs (0x33). Consulted by 0x10, for the programming handoff; nsubs == 0 = none.
	subs  [max_sub_services]SubService
	nsubs int
	// SecurityAccess (0x27) or Authentication (0x29): the seam (SecurityOps — for 0x29 its seed is
	// the challenge source), the levels served (bit L-1 for level L), the failed-key (or failed-proof)
	// limit and the lockout delay (0 = the defaults). sa_* below is the exchange in progress.
	security        SecurityOps
	// the 0x29 seam: one set (authenticates) makes the node unlock by Authentication (auth.v), and 0x27 is
	// then not served
	auth            AuthOps
	security_levels u8
	sa_attempts     u8
	sa_delay_us     u64
	sa_level        u8 // the level whose seed (0x27) or challenge (0x29) is outstanding (0 = none)
	// session_epoch counts session ENTRIES (0x10 — re-entering the same session too — S3, a reset):
	// an owner keeping an exchange outside the server knows one begun in an earlier entry is void
	session_epoch u32
	sa_seed         [seed_len]u8
	auth_challenge  [auth_challenge_len]u8 // the 0x29 challenge outstanding (valid while sa_level != 0)
	// the 0x29 proof being verified while its answer is owed (auth.v): its level (0 = none), whether
	// the verdict is in, and the answer it decided (0 = ownershipVerified, else the NRC)
	auth_level   u8
	auth_decided bool
	auth_nrc     u8
	sa_failed       [max_security_level]u8 // wrong keys (or proofs) per level: one level's unlock never clears another's
	// wrong keys per level since its last correct key, rising to the attempt limit and no further
	// (sa_failed restarts when a lockout starts; this does not): what the journal holds (sa_store.v)
	sa_since        [max_security_level]u8
	// per level: when its lockout delay ends, and the levels whose delay starts at the next tick
	// (bit L-1; a start-up or a reset, whose clock is not known yet). A level's wrong keys cost that
	// level's delay only, so a level nobody unlocks never delays another's seed.
	sa_delay_until [max_security_level]u64
	sa_arm         u8
	// The 0x27 state's persistence (sa_store.v): the journal seam (nil put = RAM only, the host),
	// the record last stored and whether the store is known to hold it, when a refused write is
	// retried, and whether a pass wrote since take_sa_wrote last asked.
	sa_store      SecurityStore
	sa_stored     [sa_record_len]u8
	sa_has_stored bool
	sa_retry_at   u64
	sa_wrote      bool
	// The service table: nservices == 0 is the DEFAULT table — every service the owner wired, in
	// its default sessions, with no service-level security (the behaviour before the table existed);
	// otherwise exactly services[0 .. nservices].
	services  [max_services]Service
	nservices int
	// Fault memory (0x19 / 0x14 / 0x85). 0x85's on/off state lives in the memory alone; the server
	// turns it back on whenever the session returns to default (like 0x28).
	faults FaultOps
	// Parameters (0x2E on a bound DID): nil `write` = a bound DID cannot be written (0x22).
	did_write DidWrite
	// Routines (0x31, routine.v): routines[0 .. nroutines], each with its request and result cells.
	routines  [max_routines]Routine
	nroutines int
	// The answer owed after a responsePending (pending.v): its service (0 = none), the routine and
	// sub-function it is for, when the next 0x78 is due, when the owed answer runs out (then, with
	// pend_fail or pend_late, when it is abandoned), whether it is to be answered
	// conditionsNotCorrect, and whether it was ready at its timeout with only the transport late.
	pend_sid   u8
	pend_idx   int
	pend_sub   u8
	pend_next  u64
	pend_until u64
	pend_fail  bool
	pend_late  bool
	// Input/output control (0x2F, io_control.v): the controlled DIDs, nio == 0 = 0x2F not served.
	ios [max_ios]IoControl
	nio int
	// io_ok is the application's conditions seam for 0x2F (REQ-DIAG-106): false answers
	// conditionsNotCorrect (0x22) and nothing changes; never asked for returnControlToECU. nil =
	// allowed — the server knows no vehicle state, and only the application can.
	io_ok fn (did u16, parameter u8) bool = unsafe { nil }
}

// init puts the server in the default session with everything unlocked-state cleared, and
// records the response capacity of the buffer the owner passes to handle(). Owners call it
// once at start; an ECUReset re-runs reset_state().
pub fn (mut s Server) init(resp_cap int) {
	// below the minimum the server stays silent (handle returns 0) instead of overrunning a
	// buffer too small for its fixed responses
	s.resp_cap = if resp_cap >= min_resp_cap { resp_cap } else { -1 }
	s.reset_state()
}


// sa_restart: what a restart makes of the 0x27 counts — a reset (reset_state) and a start-up
// (restore_persisted_security, sa_store.v) alike, ONE rule so the host bridge and a target agree:
// per served level with a wrong key counted since its last correct key, the delay is armed (the
// full delay, from the next tick: the clock that timed a running one is not trusted across it), and
// the level's lockout count is that count below the attempt limit, or 0 at or above it — after the
// delay of a saturated count the level has its attempts again, as after any lockout. The delay is
// that level's: another level's seed is not delayed. A level with nothing counted, or not served,
// arms nothing. A loop over the levels: the target has no heap.
fn (mut s Server) sa_restart() {
	limit := s.sa_max_attempts()
	for i in 0 .. max_security_level {
		if s.sa_since[i] == 0 || s.security_levels & (u8(1) << i) == 0 {
			continue
		}
		s.sa_failed[i] = if s.sa_since[i] < limit { s.sa_since[i] } else { u8(0) }
		s.sa_arm |= u8(1) << i
	}
}

// reset_state returns the diagnostic state to power-on: default session, security locked,
// communication enabled, no pending reset, every routine asked to stop and none accepted (an owed
// answer then answered 0x22, stop_routines), and every input/output control returned to the ECU
// (io_control.v). DIDs are untouched. The 0x27 failed-key counts SURVIVE
// it: a reset between guesses must not buy fresh attempts, so a reset with a wrong key of a level
// counted since that level's last correct key costs the full lockout delay (one after an ended
// lockout too, and one during a lockout restarts it), by the rule a start-up follows (sa_restart) —
// and a clean reset costs nothing.
// (Across the MCU's restart — an ECUReset, any other reset, a power cycle — a target keeps them in
// the NvM journal: sa_store.v, docs/diagnostics.md §3.1. The host bridge has no power cycle.)
pub fn (mut s Server) reset_state() {
	s.session = session_default
	s.unlocked = 0
	s.sa_level = 0
	s.session_epoch++
	s.stop_routines()
	s.sa_arm = 0
	s.sa_restart()
	for i in 0 .. max_routines {
		s.routines[i].accepted = false
	}
	s.normal_tx_off = false
	s.normal_rx_off = false
	s.restore_dtc_setting()
	s.reset_req = 0
	s.last_rx_us = 0
	s.rx_seen = false
	s.io_return_where(0, false, session_default) // every input/output control back to the ECU
}

// tick advances the server's clock and applies S3: a non-default session with no request for
// S3 returns to default (ISO 14229-2) — but never while an answer is owed, whose timeout it applies
// instead (pending_tick). Call once per owner pass, before handling requests.
pub fn (mut s Server) tick(now_us u64) {
	s.now_us = now_us
	if s.sa_arm != 0 {
		for i in 0 .. max_security_level {
			if s.sa_arm & (u8(1) << i) != 0 {
				s.sa_delay_until[i] = now_us + s.sa_delay()
			}
		}
		s.sa_arm = 0
	}
	s.pending_tick(now_us)
	if s.session == session_default || s.session == 0 || !s.rx_seen {
		return
	}
	s3 := if s.s3_us == 0 { default_s3_us } else { s.s3_us }
	if now_us > s.last_rx_us && now_us - s.last_rx_us > s3 { // a stamp not before now is no silence
		s.enter_session(session_default)
	}
}

// hold_s3 keeps S3 from running while the owner's link is busy on this connection — a request
// still being received or an answer still being sent. ISO 14229-2 starts S3 only once the
// exchange is over, so a long transfer (a large STmin) cannot time the session out mid-response,
// and a TesterPresent that arrives meanwhile and cannot be served is not needed to keep it.
// Call it before tick() in the same pass, with the same time, so the expiry check sees the hold.
pub fn (mut s Server) hold_s3(now_us u64) {
	s.now_us = now_us
	s.last_rx_us = now_us
}

// tx_enabled / rx_enabled: CommunicationControl's effect on normal communication messages, for
// the owner to gate its application frames on.
pub fn (s &Server) tx_enabled() bool {
	return !s.normal_tx_off
}

pub fn (s &Server) rx_enabled() bool {
	return !s.normal_rx_off
}

// handle dispatches one PHYSICALLY addressed UDS request (req[0..req_len]) and writes the
// response into resp, returning its length (0 = no response, e.g. suppressed).
pub fn (mut s Server) handle(req &u8, req_len int, resp &u8) int {
	return s.dispatch(req, req_len, resp)
}

// handle_functional dispatches a FUNCTIONALLY addressed request: identical, except the
// negative responses ISO 14229-1 forbids for functional requests are withheld.
pub fn (mut s Server) handle_functional(req &u8, req_len int, resp &u8) int {
	if req_len >= 1 && unsafe { req[0] == 0x27 || req[0] == 0x29 || req[0] == 0x2F || req[0] == 0x31 }
		&& s.resp_cap >= 0 {
		// SecurityAccess and Authentication are physical-only: a broadcast key or proof would spend a
		// guess on every ECU. So is InputOutputControl: an override is one ECU's, never every ECU's at
		// once. And so is RoutineControl: a routine is an action on one ECU, its answer owed to one
		// requester. Each is still a request, so it keeps the session alive like any other (S3).
		s.last_rx_us = s.now_us
		s.rx_seen = true
		return 0
	}
	n := s.dispatch(req, req_len, resp)
	if n == 3 && unsafe { resp[0] } == 0x7F {
		nrc := unsafe { resp[2] }
		if nrc == nrc_service_not_supported || nrc == nrc_subfunction_not_supported
			|| nrc == nrc_request_out_of_range || nrc == nrc_subfunction_not_in_session
			|| nrc == nrc_service_not_in_session {
			return 0
		}
	}
	return n
}

fn (mut s Server) dispatch(req &u8, req_len int, resp &u8) int {
	if req_len < 1 || s.resp_cap < 0 {
		return 0
	}
	if s.pend_sid != 0 {
		return 0 // an answer is owed: every request is dropped, unanswered and unperformed (pending.v)
	}
	s.last_rx_us = s.now_us // any request keeps the session alive (S3)
	s.rx_seen = true
	sid := unsafe { req[0] }
	if !s.service_supported(sid) {
		return negative(resp, sid, nrc_service_not_supported)
	}
	row, listed := s.service_row(sid)
	if !listed {
		return negative(resp, sid, nrc_service_not_supported)
	}
	if !in_mask(row.sessions, s.session) {
		return negative(resp, sid, nrc_service_not_in_session)
	}
	// ISO 14229-1's order: supported → in the active session → the service's security → the rest
	if row.security != 0 && s.unlocked != row.security {
		return negative(resp, sid, nrc_security_access_denied)
	}
	match sid {
		0x3E { return s.tester_present(req, req_len, resp) }
		0x10 { return s.session_control(req, req_len, resp) }
		0x11 { return s.ecu_reset(req, req_len, resp) }
		0x22 { return s.read_did(req, req_len, resp) }
		0x27 { return s.security_access(req, req_len, resp) }
		0x29 { return s.authentication(req, req_len, resp) }
		0x14 { return s.clear_dtcs(req, req_len, resp) }
		0x19 { return s.read_dtcs(req, req_len, resp) }
		0x85 { return s.dtc_setting(req, req_len, resp) }
		0x28 { return s.communication_control(req, req_len, resp) }
		0x2E { return s.write_did(req, req_len, resp) }
		0x2F { return s.io_control(req, req_len, resp) }
		0x31 { return s.routine_control(req, req_len, resp) }
		else { return negative(resp, sid, nrc_service_not_supported) }
	}
}

// service_supported: the SIDs dispatch() serves — kept in step with its match by
// test_every_supported_service_dispatches, which fails if a SID is listed here and not handled.
fn (s &Server) service_supported(sid u8) bool {
	return match sid {
		0x10, 0x22, 0x2E, 0x3E { true }
		0x11 { s.serves_reset }
		0x14, 0x19 { s.faults.avail != 0 && s.faults.entry != unsafe { nil } && s.faults.count != unsafe { nil } && s.faults.clear != unsafe { nil } }
		0x85 { s.faults.avail != 0 && s.faults.set_setting != unsafe { nil } }
		0x27 { !s.authenticates() && s.security.seed != unsafe { nil } && s.security.key_ok != unsafe { nil } && s.security_levels != 0 }
		0x29 { s.authenticates() && s.security.seed != unsafe { nil } && s.security_levels != 0 }
		0x28 { s.serves_comm_control }
		0x2F { s.nio > 0 }
		0x31 { s.nroutines > 0 }
		else { false }
	}
}

// service_row: the table's row for `sid` with its sessions resolved (a row's 0 = the service's
// default), and false when a configured table leaves the service out. The default table
// (nservices == 0) is a row per service in its default sessions with no security.
fn (s &Server) service_row(sid u8) (Service, bool) {
	if s.nservices == 0 {
		return Service{
			sid:      sid
			sessions: default_sessions(sid)
		}, true
	}
	for i in 0 .. s.nservices {
		if i >= max_services {
			break
		}
		if s.services[i].sid == sid {
			mut row := s.services[i]
			if row.sessions == 0 {
				row.sessions = default_sessions(sid)
			}
			return row, true
		}
	}
	return Service{}, false
}

// default_sessions: where each service may run unless the table says otherwise (0 = every
// session). CommunicationControl, SecurityAccess, InputOutputControl and ControlDTCSetting are
// non-default-session services (a tester must enter extended first, so a stray request on a quiet
// bus cannot silence an ECU, spend its key attempts, override its outputs or freeze its fault
// memory); Authentication, which ISO 14229-1 also allows in the default session, is kept out of it
// here like 0x27 (REQ-DIAG-121: every session entry relocks) — a table never opens any of them in
// the default session (loom2v refuses that). Per-DID gating sits on top for 0x22/0x2E/0x2F.
pub fn default_sessions(sid u8) u8 {
	return match sid {
		0x27, 0x28, 0x29, 0x2F, 0x85 { in_extended | in_programming }
		else { u8(0) }
	}
}

// default_handoff_sessions: where an application server accepts the programming handoff (0x10 02)
// when no sub-function row names it (session_control applies it) — the extended session, so a stray request on a quiet
// bus cannot restart a running ECU into its bootloader (as default_sessions keeps 0x27/0x28/0x85).
pub const default_handoff_sessions = in_extended

// in_mask: `session` is allowed by `mask` (0 = every session). A server that never entered a
// session (0) is allowed nowhere a mask names — fail-closed.
fn in_mask(mask u8, session u8) bool {
	if mask == 0 {
		return true
	}
	if session == 0 || session > 8 {
		return false
	}
	return mask & (u8(1) << (session - 1)) != 0
}

// enter_session changes the active session. EVERY entry relocks security, voids an outstanding
// seed and asks every running routine to stop (stop_routines) — re-entering the session already
// active included (ISO 14229-1: security is per session instance, and the plan's "every
// transition, explicit or by S3") — and a return to
// the default session re-enables communication (0x28 state does not survive leaving the
// non-default session).
// end_session returns to the default session as S3 would — relocked, the exchange voided — without
// touching a pending reset (an owner ending one tester's session must not cancel another's reset).
pub fn (mut s Server) end_session() {
	s.enter_session(session_default)
}

fn (mut s Server) enter_session(session u8) {
	s.unlocked = 0
	s.sa_level = 0
	s.session_epoch++
	s.session = session
	s.stop_routines()
	if session == session_default {
		s.normal_tx_off = false
		s.normal_rx_off = false
		s.restore_dtc_setting()
	}
	s.io_return_where(0, false, session) // the controls this entry's relock or session ends
}

// restore_dtc_setting turns DTC setting back on when a session ends (explicitly, by S3, or by a
// reset) — ISO 14229-1 ControlDTCSetting: DTC status updating resumes on the transition to the
// default session (and on reset); a switch between non-default sessions keeps it off (§7, R4).
fn (mut s Server) restore_dtc_setting() {
	if s.faults.set_setting != unsafe { nil } {
		s.faults.set_setting(s.faults.ctx, true)
	}
}

fn (s &Server) cap() int {
	return if s.resp_cap > 0 { s.resp_cap } else { legacy_resp_cap }
}

fn (mut s Server) tester_present(req &u8, req_len int, resp &u8) int {
	if req_len < 2 {
		return negative(resp, 0x3E, nrc_incorrect_length)
	}
	sub := unsafe { req[1] } & 0x7F
	// TesterPresent's only valid subfunction is 0x00 (ISO 14229): validate BEFORE
	// honoring suppression — an invalid subfunction gets a negative response even with
	// the suppress bit set (codex #218: '3E 81' was silently accepted)
	if sub != 0x00 {
		return negative(resp, 0x3E, nrc_subfunction_not_supported)
	}
	if req_len != 2 {
		return negative(resp, 0x3E, nrc_incorrect_length)
	}
	if unsafe { req[1] } & 0x80 != 0 {
		return 0 // suppressPosRsp on the VALID subfunction: stay silent
	}
	unsafe {
		resp[0] = 0x7E
		resp[1] = 0x00
	}
	return 2
}

fn (mut s Server) session_control(req &u8, req_len int, resp &u8) int {
	if req_len < 2 {
		return negative(resp, 0x10, nrc_incorrect_length)
	}
	sub := unsafe { req[1] } & 0x7F // suppressPosRspMsgIndicationBit (0x80) is not the session
	// validate BEFORE mutating or suppressing: suppression applies only to a SUCCESSFUL
	// positive response — an unsupported session must still get a negative response
	// (REQ-DIAG-001; codex #218: '10 FF' stored 0x7F and stayed silent)
	if sub != session_default && sub != session_programming && sub != session_extended
		&& sub != session_safety {
		return negative(resp, 0x10, nrc_subfunction_not_supported)
	}
	handoff := sub == session_programming && s.no_programming
	if handoff && !s.boot_handoff {
		return negative(resp, 0x10, nrc_subfunction_not_supported)
	}
	// ISO 14229-1's order past a supported sub-function: in the active session (0x7E) → its
	// security (0x33) → the exact length (0x13) → conditions (0x22)
	mut gate, listed := s.sub_refusal(0x10, sub)
	if handoff && !listed && !in_mask(default_handoff_sessions, s.session) {
		gate = nrc_subfunction_not_in_session // no row of its own: its default sessions
	}
	if gate != 0 {
		return negative(resp, 0x10, gate)
	}
	if req_len != 2 {
		return negative(resp, 0x10, nrc_incorrect_length)
	}
	if handoff {
		if s.handoff_elsewhere || (s.handoff_ok != unsafe { nil } && !s.handoff_ok()) {
			return negative(resp, 0x10, nrc_conditions_not_correct)
		}
		// answered HERE, before the reset: the session is opened by the bootloader's server after
		// it, and nothing changes in this one — a handoff whose answer is lost is cancelled with
		// the server exactly as it was (comm/diag cancel_reset)
		s.reset_req = reset_into_boot
		if unsafe { req[1] } & 0x80 != 0 {
			return 0
		}
		return session_answer(resp, sub)
	}
	s.enter_session(sub)
	if unsafe { req[1] } & 0x80 != 0 {
		return 0 // suppressPosRsp on a VALID session: action done, response withheld
	}
	return session_answer(resp, s.session)
}

// session_answer: the 0x10 positive response — the session and the timing record, which is ONE
// statement for every server built on this one, the bootloader's included, so the P2/P2* an
// application announces in answer to a handoff are the ones the bootloader's session keeps.
// The timing is pending.v's p2_server_us (in ms) and p2_star_server_us (in 10 ms units).
fn session_answer(resp &u8, session u8) int {
	p2 := u16(p2_server_us / 1000) // 0x0032: 50 ms
	p2_star := u16(p2_star_server_us / 10_000) // 0x01F4 * 10 ms: 5 s
	unsafe {
		resp[0] = 0x50
		resp[1] = session
		resp[2] = u8(p2 >> 8)
		resp[3] = u8(p2)
		resp[4] = u8(p2_star >> 8)
		resp[5] = u8(p2_star)
	}
	return 6
}

// sub_refusal: the NRC a sub-function row refuses `sub` of `sid` with in the active session and
// unlock — 0x7E outside its sessions, 0x33 without its level — or 0 when it passes; and whether
// the sub-function has a row at all.
fn (s &Server) sub_refusal(sid u8, sub u8) (u8, bool) {
	for i in 0 .. s.nsubs {
		if i >= max_sub_services {
			break
		}
		r := s.subs[i]
		if r.sid != sid || r.sub != sub {
			continue
		}
		if !in_mask(r.sessions, s.session) {
			return nrc_subfunction_not_in_session, true
		}
		if r.security != 0 && s.unlocked != r.security {
			return nrc_security_access_denied, true
		}
		return 0, true
	}
	return 0, false
}

// ecu_reset: hardReset (01) and softReset (03). The server only RECORDS the request —
// reset_req — and answers; the owner performs the reset once the response has left, because
// resetting first would lose the answer the tester waits for.
fn (mut s Server) ecu_reset(req &u8, req_len int, resp &u8) int {
	if req_len < 2 {
		return negative(resp, 0x11, nrc_incorrect_length)
	}
	sub := unsafe { req[1] } & 0x7F
	if sub != 0x01 && sub != 0x03 {
		return negative(resp, 0x11, nrc_subfunction_not_supported)
	}
	if req_len != 2 {
		return negative(resp, 0x11, nrc_incorrect_length)
	}
	s.reset_req = sub
	if unsafe { req[1] } & 0x80 != 0 {
		return 0
	}
	unsafe {
		resp[0] = 0x51
		resp[1] = sub
	}
	return 2
}

// communication_control: enableRxAndTx (00), enableRxAndDisableTx (01), disableRxAndEnableTx
// (02), disableRxAndTx (03), for communicationType NORMAL messages (1) — network management (2,
// 3) is refused until NM is gated by it — on "all networks" (subnet 0) or "the network this
// request arrived on" (subnet 0xF). A node with several networks cannot act on all of them from
// one bridge, so subnet 0 is accepted only where there is one network; a specific subnet number
// is out of range. It governs the ECU's OWN application messages: frames a gateway forwards
// between buses are routed traffic, not this server's communication, and keep flowing.
fn (mut s Server) communication_control(req &u8, req_len int, resp &u8) int {
	if req_len < 2 {
		return negative(resp, 0x28, nrc_incorrect_length)
	}
	sub := unsafe { req[1] } & 0x7F
	if sub > 0x03 {
		return negative(resp, 0x28, nrc_subfunction_not_supported)
	}
	if req_len != 3 {
		return negative(resp, 0x28, nrc_incorrect_length)
	}
	ctype := unsafe { req[2] }
	kind := ctype & 0x03
	subnet := ctype >> 4
	if kind != 0x01 || ctype & 0x0C != 0 {
		return negative(resp, 0x28, nrc_request_out_of_range)
	}
	if subnet != 0x0F && !(subnet == 0 && s.single_network) {
		return negative(resp, 0x28, nrc_request_out_of_range)
	}
	rx_off := sub == 0x02 || sub == 0x03
	tx_off := sub == 0x01 || sub == 0x03
	s.normal_rx_off = rx_off
	s.normal_tx_off = tx_off
	if unsafe { req[1] } & 0x80 != 0 {
		return 0
	}
	unsafe {
		resp[0] = 0x68
		resp[1] = sub
	}
	return 2
}

fn (s &Server) sa_delay() u64 {
	return if s.sa_delay_us == 0 { default_sa_delay_us } else { s.sa_delay_us }
}

fn (s &Server) sa_max_attempts() u8 {
	return attempts_of(s.sa_attempts)
}

// attempts_of: the attempt limit a configured `security_attempts` gives (0 = the default) — the one
// rule, which the generator's wear check multiplies by too
pub fn attempts_of(configured u8) u8 {
	return if configured == 0 { default_sa_attempts } else { configured }
}

// security_access (0x27). requestSeed (odd subfunction 2L-1) hands out a fresh seed for level L —
// all zeros when L is already unlocked (ISO 14229-1) — and sendKey (2L) checks a key against the
// OUTSTANDING seed of that same level, once: a wrong key spends the seed. After sa_attempts wrong
// keys the answer is exceededNumberOfAttempts and no seed is issued, nor a key judged, until the
// lockout delay has passed (requiredTimeDelayNotExpired); a reset with a wrong key counted since the
// level's last correct key costs the delay too (reset_state). On a target the count is in the journal before the
// answer reporting it is pumped (sa_store.v); a write the journal refuses changes no answer.
// requestSeed always answers, since the seed IS the answer; sendKey honours the suppress bit.
fn (mut s Server) security_access(req &u8, req_len int, resp &u8) int {
	if req_len < 2 {
		return negative(resp, 0x27, nrc_incorrect_length)
	}
	sub := unsafe { req[1] } & 0x7F
	level := (sub + 1) / 2
	if sub == 0 || level > max_security_level || s.security_levels & (u8(1) << (level - 1)) == 0 {
		return negative(resp, 0x27, nrc_subfunction_not_supported)
	}
	if sub & 1 == 1 {
		return s.request_seed(level, sub, resp)
	}
	return s.send_key(level, req, req_len, resp)
}

fn (mut s Server) request_seed(level u8, sub u8, resp &u8) int {
	// an optional securityAccessDataRecord after the subfunction is accepted and ignored; the
	// delay refused here is this level's (its lockout, or one a start-up or reset armed for it)
	if s.sa_delayed(level) {
		return negative(resp, 0x27, nrc_time_delay_not_expired)
	}
	s.sa_level = 0
	if s.unlocked == level {
		unsafe {
			resp[0] = 0x67
			resp[1] = sub
			for i in 0 .. seed_len {
				resp[2 + i] = 0
			}
		}
		return 2 + seed_len
	}
	if !s.security.seed(s.security.ctx, &s.sa_seed[0], seed_len) {
		return negative(resp, 0x27, nrc_conditions_not_correct)
	}
	mut zero := true
	for b in s.sa_seed {
		if b != 0 {
			zero = false
		}
	}
	if zero {
		// all zeros means "already unlocked" on the wire: never hand it out as a real seed
		return negative(resp, 0x27, nrc_conditions_not_correct)
	}
	s.sa_level = level
	unsafe {
		resp[0] = 0x67
		resp[1] = sub
		for i in 0 .. seed_len {
			resp[2 + i] = s.sa_seed[i]
		}
	}
	return 2 + seed_len
}

fn (mut s Server) send_key(level u8, req &u8, req_len int, resp &u8) int {
	if req_len != 2 + seed_len {
		return negative(resp, 0x27, nrc_incorrect_length)
	}
	if s.sa_level != level {
		return negative(resp, 0x27, nrc_request_sequence_error) // no seed of this level outstanding
	}
	s.sa_level = 0 // one key per seed
	if s.sa_delayed(level) {
		return negative(resp, 0x27, nrc_time_delay_not_expired)
	}
	if !s.security.key_ok(s.security.ctx, level, &s.sa_seed[0], unsafe { req + 2 }, seed_len) {
		return negative(resp, 0x27, s.sa_wrong(level, nrc_invalid_key))
	}
	s.sa_granted(level)
	if unsafe { req[1] } & 0x80 != 0 {
		return 0
	}
	unsafe {
		resp[0] = 0x67
		resp[1] = req[1]
	}
	return 2
}

// sa_delayed: level's seed (or challenge) is refused for now — its lockout runs, or a start-up or
// reset armed its delay for the next tick
fn (s &Server) sa_delayed(level u8) bool {
	return s.sa_arm & (u8(1) << (level - 1)) != 0 || s.now_us < s.sa_delay_until[level - 1]
}

// sa_wrong: a wrong 0x27 key or a failed 0x29 proof of `level`, counted — ONE count per level for
// both, so a node's attempt limit, lockout and persisted record (sa_store.v) hold for either. The NRC
// to answer: `wrong` (0x35 / 0x58), or 0x36 when this one reached the limit and started the lockout.
fn (mut s Server) sa_wrong(level u8, wrong u8) u8 {
	if s.sa_since[level - 1] < s.sa_max_attempts() {
		s.sa_since[level - 1]++
	}
	s.sa_failed[level - 1]++
	if s.sa_failed[level - 1] >= s.sa_max_attempts() {
		s.sa_failed[level - 1] = 0
		s.sa_delay_until[level - 1] = s.now_us + s.sa_delay()
		return nrc_exceeded_attempts
	}
	return wrong
}

// sa_granted: a correct key or proof of `level` — unlocked, its count cleared, and the level unlocked
// before relocked: its controls are returned, its routines asked to stop (end_levels) — one rule for
// 0x27 and 0x29
fn (mut s Server) sa_granted(level u8) {
	s.sa_failed[level - 1] = 0
	s.sa_since[level - 1] = 0
	s.unlocked = level
	s.end_levels(level, true)
}

// ReferenceSecurity is the SIM / BENCH key, NOT a secret: key[i] = seed[i] XOR 0xFF, the reference
// algorithm blobly_net's client already implements (uds.security_key), so tester and server unlock
// with ONE algorithm (decision D5). Its seeds come from a xorshift generator — unpredictable enough
// for a test, not for a vehicle. A production image injects its own SecurityOps.
pub struct ReferenceSecurity {
pub mut:
	state u32
}

// ops returns the SecurityOps backed by `r`, whose generator starts from `entropy` (any value; 0 is
// replaced, since xorshift never leaves zero). `r` must outlive the server that holds the ops.
pub fn (mut r ReferenceSecurity) ops(entropy u32) SecurityOps {
	r.state = if entropy == 0 { u32(0x9E3779B9) } else { entropy }
	return SecurityOps{
		ctx:    unsafe { voidptr(&r) }
		seed:   reference_seed
		key_ok: reference_key_ok
	}
}

fn reference_seed(ctx voidptr, out &u8, n int) bool {
	mut r := unsafe { &ReferenceSecurity(ctx) }
	for i in 0 .. n {
		r.state ^= r.state << 13
		r.state ^= r.state >> 17
		r.state ^= r.state << 5
		unsafe {
			out[i] = u8(r.state >> 24)
		}
	}
	return true
}

// reference_key_ok is blobly_net's reference key check (key[i] = seed[i] ^ 0xFF) — public for a
// target that opts into the bench key by name (`[uds] security_key = "reference"`).
pub fn reference_key_ok(ctx voidptr, level u8, seed &u8, key &u8, n int) bool {
	for i in 0 .. n {
		if unsafe { key[i] != seed[i] ^ 0xFF } {
			return false
		}
	}
	return true
}

// did_active_session is ISO 14229-1's ActiveDiagnosticSessionDataIdentifier: served by the server
// itself (one byte, the active session) in every session and behind no level, so it is never a
// [[did]] of the table — a write to it is out of range like any read-only DID's (REQ-DIAG-063).
pub const did_active_session = u16(0xF186)

// served_did_len: the record length of a DID the server serves itself, 0 for any other — the one
// place read_did's sizing and writing passes take it from (an uninitialised server, session 0, has
// no session to report).
fn (s &Server) served_did_len(id u16) int {
	return if id == did_active_session && s.session != 0 { 1 } else { 0 }
}

// find_did: the table index of `id`, or -1.
fn (s &Server) find_did(id u16) int {
	for i in 0 .. s.ndid {
		if s.dids[i].id == id {
			return i
		}
	}
	return -1
}

// The lengths of the answers below, for whoever must size a buffer to hold them (generation refuses
// a node's maximum message length that cannot, REQ-CAN-TP-022). Stated beside the writers they
// describe and pinned against their bytes in uds_test.v.

// did_answer_len: a 0x22 answer carrying one DID of `len` data bytes — and the 0x2E request writing
// it, which has the same shape (the service, the identifier, the data).
pub fn did_answer_len(len int) int {
	return 3 + len
}

// dtc_list_len: a 0x19 02 / 0A answer listing `n` DTCs (the subfunction, the availability mask,
// then each DTC and its status).
pub fn dtc_list_len(n int) int {
	return 3 + 4 * n
}

// dtc_records_head: what a 0x19 04 / 06 answer carries before its records (the subfunction, the
// DTC and its status).
pub const dtc_records_head = 6

// snapshot_answer_len: a 0x19 04 answer carrying one snapshot record whose body is `body` bytes
// (the record number, then the body: comm/fault's snapshot_body_len).
pub fn snapshot_answer_len(body int) int {
	return dtc_records_head + 1 + body
}

// read_did serves one or MORE DIDs per request (ISO 14229-1 0x22): each supported DID's record —
// the table's, or one the server serves itself (served_did_len) — is appended in request order. A
// DID that does not exist, or is not readable in the active session, is simply not answered; only
// a request in which NONE is answered gets 0x31. A DID that exists but needs a security level not
// unlocked denies the whole request with 0x33. The response must fit the owner's buffer (0x14
// otherwise) — checked before anything is written.
fn (mut s Server) read_did(req &u8, req_len int, resp &u8) int {
	if req_len < 3 || (req_len - 1) % 2 != 0 {
		return negative(resp, 0x22, nrc_incorrect_length)
	}
	ndid := (req_len - 1) / 2
	mut total := 1
	mut answered := 0
	for k in 0 .. ndid {
		id := unsafe { (u16(req[1 + 2 * k]) << 8) | u16(req[2 + 2 * k]) }
		served := s.served_did_len(id)
		if served > 0 {
			total += 2 + served
			answered++
			continue
		}
		i := s.find_did(id)
		if i < 0 || !in_mask(s.dids[i].read_sessions, s.session) {
			continue
		}
		if s.dids[i].read_security != 0 && s.unlocked != s.dids[i].read_security {
			return negative(resp, 0x22, nrc_security_access_denied)
		}
		total += 2 + int(s.dids[i].len)
		answered++
	}
	if answered == 0 {
		return negative(resp, 0x22, nrc_request_out_of_range)
	}
	if total > s.cap() {
		return negative(resp, 0x22, nrc_response_too_long)
	}
	unsafe {
		resp[0] = 0x62
	}
	mut o := 1
	for k in 0 .. ndid {
		id := unsafe { (u16(req[1 + 2 * k]) << 8) | u16(req[2 + 2 * k]) }
		served := s.served_did_len(id)
		if served > 0 {
			unsafe {
				resp[o] = u8(id >> 8)
				resp[o + 1] = u8(id)
				resp[o + 2] = s.session // did_active_session, its one byte
			}
			o += 2 + served
			continue
		}
		i := s.find_did(id)
		if i < 0 || !in_mask(s.dids[i].read_sessions, s.session) {
			continue
		}
		unsafe {
			resp[o] = u8(id >> 8)
			resp[o + 1] = u8(id)
			for j in 0 .. int(s.dids[i].len) {
				resp[o + 2 + j] = s.dids[i].data[j]
			}
		}
		o += 2 + int(s.dids[i].len)
	}
	return o
}

fn (mut s Server) write_did(req &u8, req_len int, resp &u8) int {
	if req_len < 4 {
		return negative(resp, 0x2E, nrc_incorrect_length)
	}
	did := unsafe { (u16(req[1]) << 8) | u16(req[2]) }
	n := req_len - 3
	i := s.find_did(did)
	// ISO 14229-1 0x2E order: a DID that does not exist, is not writable, or is not writable
	// in the active session is NOT SUPPORTED for write (0x31); then security (0x33); then the
	// record length (0x13); then, for a parameter, its conditions (0x22), range (0x31) and the
	// write itself (0x72) — the seam's.
	if i < 0 || !s.dids[i].writable || !in_mask(s.dids[i].write_sessions, s.session) {
		return negative(resp, 0x2E, nrc_request_out_of_range)
	}
	if s.dids[i].write_security != 0 && s.unlocked != s.dids[i].write_security {
		return negative(resp, 0x2E, nrc_security_access_denied)
	}
	// a writable DID's declared size is its `len` — a RAM cell's configured bytes, a parameter's
	// record width (comm/param bind) — and a record of any other length is refused: a write
	// never changes a DID's size (and never writes past the cell, whatever `len` was set to)
	if n != int(s.dids[i].len) || n > max_did_data {
		return negative(resp, 0x2E, nrc_incorrect_length)
	}
	if s.dids[i].bound {
		if s.did_write.write == unsafe { nil } {
			return negative(resp, 0x2E, nrc_conditions_not_correct)
		}
		nrc := s.did_write.write(s.did_write.ctx, did, unsafe { req + 3 }, n)
		if nrc != 0 {
			return negative(resp, 0x2E, nrc)
		}
	}
	unsafe {
		for j in 0 .. n {
			s.dids[i].data[j] = req[3 + j]
		}
	}
	unsafe {
		resp[0] = 0x6E
		resp[1] = req[1]
		resp[2] = req[2]
	}
	return 3
}

// read_dtcs (0x19) — the subfunctions served (D6): 0x01 reportNumberOfDTCByStatusMask, 0x02
// reportDTCByStatusMask, 0x0A reportSupportedDTC, and with snapshots / extended data (R6b) 0x03
// reportDTCSnapshotIdentification, 0x04 reportDTCSnapshotRecordByDTCNumber, 0x06
// reportDTCExtDataRecordByDTCNumber. A DTC matches a mask when (status & mask & availability) != 0.
// The response must fit the owner's buffer (0x14 otherwise), checked before anything is written.
// 0x19 has no suppressPosRsp: bit 7 makes the subfunction unsupported.
fn (mut s Server) read_dtcs(req &u8, req_len int, resp &u8) int {
	if req_len < 2 {
		return negative(resp, 0x19, nrc_incorrect_length)
	}
	sub := unsafe { req[1] }
	// each subfunction is served by its own seam: 03 / 04 by `snapshot`, 06 by `extended`
	snaps := s.faults.snapshot != unsafe { nil }
	ext := s.faults.extended != unsafe { nil }
	want := match sub {
		0x01, 0x02 { 3 }
		0x0A { 2 }
		0x03 { if snaps { 2 } else { 0 } }
		0x04 { if snaps { 6 } else { 0 } }
		0x06 { if ext { 6 } else { 0 } }
		else { 0 }
	}
	if want == 0 {
		return negative(resp, 0x19, nrc_subfunction_not_supported)
	}
	if req_len != want {
		return negative(resp, 0x19, nrc_incorrect_length)
	}
	if sub == 0x03 {
		return s.snapshot_ids(resp)
	}
	if sub == 0x04 || sub == 0x06 {
		return s.dtc_records(sub, req, resp)
	}
	avail := s.faults.avail
	mask := if sub == 0x0A { u8(0xFF) } else { unsafe { req[2] } & avail }
	n := s.faults.count(s.faults.ctx)
	mut hits := 0
	for i in 0 .. n {
		e := s.faults.entry(s.faults.ctx, i)
		if sub == 0x0A || u8(e) & mask != 0 {
			hits++
		}
	}
	if sub == 0x01 {
		unsafe {
			resp[0] = 0x59
			resp[1] = 0x01
			resp[2] = avail
			resp[3] = 0x01 // DTCFormatIdentifier: ISO_14229-1_DTCFormat
			resp[4] = u8(hits >> 8)
			resp[5] = u8(hits)
		}
		return 6
	}
	total := dtc_list_len(hits)
	if total > s.cap() {
		return negative(resp, 0x19, nrc_response_too_long)
	}
	unsafe {
		resp[0] = 0x59
		resp[1] = sub
		resp[2] = avail
	}
	mut o := 3
	for i in 0 .. n {
		e := s.faults.entry(s.faults.ctx, i)
		if sub != 0x0A && u8(e) & mask == 0 {
			continue
		}
		unsafe {
			resp[o] = u8(e >> 24)
			resp[o + 1] = u8(e >> 16)
			resp[o + 2] = u8(e >> 8)
			resp[o + 3] = u8(e) // the status (for 0x0A, all bits as maintained)
		}
		o += 4
	}
	return o
}

// snapshot_ids (0x19 03): every DTC with a stored snapshot, each with its record number (0x01 —
// one snapshot per DTC).
fn (mut s Server) snapshot_ids(resp &u8) int {
	n := s.faults.count(s.faults.ctx)
	mut hits := 0
	for i in 0 .. n {
		if s.faults.snapshot(s.faults.ctx, i, unsafe { nil }, 0) > 0 {
			hits++
		}
	}
	if 2 + 4 * hits > s.cap() {
		return negative(resp, 0x19, nrc_response_too_long)
	}
	unsafe {
		resp[0] = 0x59
		resp[1] = 0x03
	}
	mut o := 2
	for i in 0 .. n {
		if s.faults.snapshot(s.faults.ctx, i, unsafe { nil }, 0) <= 0 {
			continue
		}
		e := s.faults.entry(s.faults.ctx, i)
		unsafe {
			resp[o] = u8(e >> 24)
			resp[o + 1] = u8(e >> 16)
			resp[o + 2] = u8(e >> 8)
			resp[o + 3] = 0x01 // DTCSnapshotRecordNumber
		}
		o += 4
	}
	return o
}

// dtc_records (0x19 04 / 06): one DTC's snapshot record (0x01, or 0xFF for all) or extended data
// records (1 .. ext_records, or 0xFF for all), after the DTC and its status. An unknown DTC or a
// record number the server does not define is requestOutOfRange; a defined record that is not
// stored is simply absent from the answer.
fn (mut s Server) dtc_records(sub u8, req &u8, resp &u8) int {
	dtc := unsafe { u32(req[2]) << 16 | u32(req[3]) << 8 | u32(req[4]) }
	rec := unsafe { req[5] }
	n := s.faults.count(s.faults.ctx)
	mut i := -1
	mut e := u32(0)
	for j in 0 .. n {
		e = s.faults.entry(s.faults.ctx, j)
		if e >> 8 == dtc {
			i = j
			break
		}
	}
	if i < 0 {
		return negative(resp, 0x19, nrc_request_out_of_range)
	}
	defined := if sub == 0x04 {
		rec == 0x01 || rec == 0xFF
	} else {
		rec == 0xFF || (rec >= 1 && rec <= s.faults.ext_records)
	}
	if !defined {
		return negative(resp, 0x19, nrc_request_out_of_range)
	}
	cap := s.cap()
	unsafe {
		resp[0] = 0x59
		resp[1] = sub
		resp[2] = u8(dtc >> 16)
		resp[3] = u8(dtc >> 8)
		resp[4] = u8(dtc)
		resp[5] = u8(e) & s.faults.avail
	}
	mut o := dtc_records_head
	if sub == 0x04 {
		len := s.faults.snapshot(s.faults.ctx, i, unsafe { nil }, 0)
		if len > 0 {
			if o + 1 + len > cap {
				return negative(resp, 0x19, nrc_response_too_long)
			}
			unsafe {
				resp[o] = 0x01
			}
			if s.faults.snapshot(s.faults.ctx, i, unsafe { &resp[o + 1] }, cap - o - 1) != len {
				return negative(resp, 0x19, nrc_response_too_long)
			}
			o += 1 + len
		}
		return o
	}
	first := if rec == 0xFF { u8(1) } else { rec }
	last := if rec == 0xFF { s.faults.ext_records } else { rec }
	for r in first .. last + 1 {
		// straight into the response, bounded by what is left of it (a record that does not exist
		// needs no room)
		room := if cap - o - 1 > 0 { cap - o - 1 } else { 0 }
		len := s.faults.extended(s.faults.ctx, i, r, unsafe { &resp[o + 1] }, room)
		if len < 0 || len > room {
			return negative(resp, 0x19, nrc_response_too_long)
		}
		if len == 0 {
			continue
		}
		unsafe {
			resp[o] = r
		}
		o += 1 + len
	}
	return o
}

// clear_dtcs (0x14) — ClearDiagnosticInformation: the 3-byte groupOfDTC, 0xFFFFFF for all or one
// DTC; an unknown DTC is out of range (0x31). No subfunction, so no suppression.
fn (mut s Server) clear_dtcs(req &u8, req_len int, resp &u8) int {
	if req_len != 4 {
		return negative(resp, 0x14, nrc_incorrect_length)
	}
	group := unsafe { u32(req[1]) << 16 | u32(req[2]) << 8 | u32(req[3]) }
	nrc := s.faults.clear(s.faults.ctx, group)
	if nrc != 0 {
		return negative(resp, 0x14, nrc) // 0x31 unknown DTC, 0x22 not clearable right now
	}
	unsafe {
		resp[0] = 0x54
	}
	return 1
}

// dtc_setting (0x85) — ControlDTCSetting on (01) / off (02), extended or programming session only;
// an optional DTCSettingControlOptionRecord after the subfunction is accepted and ignored. "Off"
// stops the fault memory updating any status until "on", or until the session ends.
fn (mut s Server) dtc_setting(req &u8, req_len int, resp &u8) int {
	if req_len < 2 {
		return negative(resp, 0x85, nrc_incorrect_length)
	}
	sub := unsafe { req[1] } & 0x7F
	if sub != 0x01 && sub != 0x02 {
		return negative(resp, 0x85, nrc_subfunction_not_supported)
	}
	s.faults.set_setting(s.faults.ctx, sub == 0x01)
	if unsafe { req[1] } & 0x80 != 0 {
		return 0
	}
	unsafe {
		resp[0] = 0xC5
		resp[1] = sub
	}
	return 2
}

fn negative(resp &u8, sid u8, nrc u8) int {
	unsafe {
		resp[0] = 0x7F
		resp[1] = sid
		resp[2] = nrc
	}
	return 3
}
