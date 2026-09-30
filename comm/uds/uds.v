module uds

// UDS (ISO 14229-1) server, no-alloc and transport-agnostic. It sits above ISO-TP (or DoIP):
// the owner hands it a reassembled request and ships the response it produces. Table-driven so
// the protocol logic is shared and unit-tested; the DIDs (and any live-signal refresh) are
// filled in by the generated bridge (docs/diagnostics.md §3.1).
//
// Services: 0x10 DiagnosticSessionControl, 0x11 ECUReset, 0x22 ReadDataByIdentifier (several
// DIDs per request), 0x27 SecurityAccess (with injected SecurityOps), 0x28 CommunicationControl,
// 0x14 / 0x19 / 0x85 over an injected FaultOps (comm/fault),
// 0x2E WriteDataByIdentifier, 0x3E TesterPresent. Anything else -> 0x11 serviceNotSupported.
//
// Negative responses follow ISO 14229-1's evaluation order. Every service: supported (0x11) →
// allowed in the active session (0x7F) → minimum length (0x13); then, for a subfunction service:
// subfunction supported (0x12) → exact length (0x13) → conditions / range. The DID services follow
// their own flow: 0x22 — length, then each DID's support and session (0x31 when none answers),
// then security (0x33), then the response size (0x14); 0x2E — length, then the DID's support,
// writability and session (0x31), then security (0x33), then the record length (0x13). 0x27 —
// subfunction (0x12), then requestSeed: the lockout delay (0x37); sendKey: length (0x13), a seed
// of that level outstanding (0x24), the key (0x35, or 0x36 on the last allowed attempt). A
// FUNCTIONAL request never answers 0x11, 0x12, 0x31, 0x7E or 0x7F (handle_functional) — a broadcast
// into an unsupported or gated service stays silent — and a functional 0x27 is ignored outright.

pub const max_dids = 16
pub const max_did_data = 32 // bytes stored per DID

// The smallest response buffer init() accepts: the longest FIXED response (0x50 with its P2/P2*
// timing, 6 bytes). A smaller buffer could not hold even that, so the server refuses to run at all
// rather than write past it.
pub const min_resp_cap = 6

// The response capacity a caller that never called init() gets: the longest response the
// single-DID server could produce (3 + max_did_data), so every pre-existing caller's buffer
// (DoIP's 40 B, the generated bridge's 64 B) stays within bounds.
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
	seed   fn (ctx voidptr, out &u8, n int) bool
	key_ok fn (ctx voidptr, level u8, seed &u8, key &u8, n int) bool
}

// FaultOps is the fault-memory seam 0x19 / 0x14 / 0x85 are answered through (comm/fault builds
// it; docs/diagnostics.md §3.3). Nil `entry` = 0x19 and 0x14 are not supported; nil `set_setting`
// = 0x85 is not. `entry(i)` returns DTC (3 bytes) << 8 | status for i in 0 .. count().
pub struct FaultOps {
pub mut:
	ctx         voidptr
	count       fn (ctx voidptr) int
	entry       fn (ctx voidptr, i int) u32
	clear       fn (ctx voidptr, group u32) u8 // the NRC, 0 = cleared
	set_setting fn (ctx voidptr, on bool)
	avail       u8 // the status availability mask; 0 = not wired (the services stay unsupported)
}

// Did is one Data Identifier: constant bytes, a RAM cell (writable), and/or kept fresh from a
// live signal by the bridge. Access is gated per DID: the session masks (0 = every session) and
// the security level a write needs (0 = none).
pub struct Did {
pub mut:
	id             u16
	data           [max_did_data]u8
	len            u8
	writable       bool
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
	// The security level currently unlocked (0 = locked). Set by 0x27 (R1b); relocked on every
	// session transition.
	unlocked u8
	// Response capacity of the caller's buffer (init); 0 = legacy_resp_cap.
	resp_cap int
	// S3: the owner calls tick(now) each pass; a request stamps last_rx_us.
	now_us     u64
	last_rx_us u64
	rx_seen    bool // last_rx_us holds a real request time (0 is a valid clock value)
	s3_us      u64 // 0 = default_s3_us
	// ECUReset requested (the 0x11 subfunction), for the owner to perform once the response
	// has left; 0 = none.
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
	// (boot.Prog), reached by a handoff (boot cell + reset) that is not built yet — so it refuses
	// 0x10 02 rather than enter a session that cannot program. The bootloader leaves it false.
	no_programming bool
	// SecurityAccess (0x27): the seam, the levels served (bit L-1 for level L), the failed-key
	// limit and the lockout delay (0 = the defaults). sa_* below is the exchange in progress.
	security        SecurityOps
	security_levels u8
	sa_attempts     u8
	sa_delay_us     u64
	sa_level        u8 // the level whose seed is outstanding (0 = none)
	sa_seed         [seed_len]u8
	sa_failed       [max_security_level]u8 // wrong keys per level: one level's unlock never clears another's
	sa_delay_until  u64
	sa_arm_delay    bool // start the delay at the next tick (boot / reset: the clock is not known yet)
	// Fault memory (0x19 / 0x14 / 0x85). 0x85's on/off state lives in the memory alone; the server
	// turns it back on whenever the session returns to default (like 0x28).
	faults FaultOps
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


// kept_len: the bytes of SecurityAccess state an owner that restarts the MCU carries across its
// own reset — the failed-key count of each level, and whether a lockout is running.
pub const kept_len = max_security_level + 1

// kept_security is what must survive the owner's reset: a reset between guesses must buy nothing,
// and a lockout that is running — whose count the server has already zeroed — must still run.
pub fn (s &Server) kept_security() [kept_len]u8 {
	mut k := [kept_len]u8{}
	for i in 0 .. max_security_level {
		k[i] = s.sa_failed[i]
	}
	k[max_security_level] = if s.sa_arm_delay || s.now_us < s.sa_delay_until { u8(1) } else { u8(0) }
	return k
}

// restore_security takes back what kept_security kept, at boot, after init: the counts, and the
// lockout delay armed — from boot, since the clock that timed it did not survive — whenever a
// lockout was running or any count is non-zero. The same rule reset_state applies.
pub fn (mut s Server) restore_security(k [kept_len]u8) {
	for i in 0 .. max_security_level {
		s.sa_failed[i] = k[i]
	}
	s.sa_arm_delay = k[max_security_level] != 0 || s.sa_failed.any(it > 0)
}

// reset_state returns the diagnostic state to power-on: default session, security locked,
// communication enabled, no pending reset. DIDs are untouched. The 0x27 failed-key count and a
// running lockout SURVIVE it: a reset between guesses must not buy fresh attempts, so a reset
// with wrong keys already counted costs the lockout delay — and a clean reset costs nothing.
// (Across a power cycle the count is lost until the target persists it — R2, docs/diagnostics.md §7.)
pub fn (mut s Server) reset_state() {
	s.session = session_default
	s.unlocked = 0
	s.sa_level = 0
	s.sa_arm_delay = s.sa_failed.any(it > 0)
	s.normal_tx_off = false
	s.normal_rx_off = false
	s.restore_dtc_setting()
	s.reset_req = 0
	s.last_rx_us = 0
	s.rx_seen = false
}

// tick advances the server's clock and applies S3: a non-default session with no request for
// S3 returns to default (ISO 14229-2). Call once per owner pass, before handling requests.
pub fn (mut s Server) tick(now_us u64) {
	s.now_us = now_us
	if s.sa_arm_delay {
		s.sa_arm_delay = false
		s.sa_delay_until = now_us + s.sa_delay()
	}
	if s.session == session_default || s.session == 0 || !s.rx_seen {
		return
	}
	s3 := if s.s3_us == 0 { default_s3_us } else { s.s3_us }
	if now_us - s.last_rx_us > s3 {
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
	if req_len >= 1 && unsafe { req[0] } == 0x27 && s.resp_cap >= 0 {
		// SecurityAccess is physical-only: a broadcast key would spend a guess on every ECU. It is
		// still a request, so it keeps the session alive like any other (S3).
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
	s.last_rx_us = s.now_us // any request keeps the session alive (S3)
	s.rx_seen = true
	sid := unsafe { req[0] }
	if !s.service_supported(sid) {
		return negative(resp, sid, nrc_service_not_supported)
	}
	if !in_mask(service_sessions(sid), s.session) {
		return negative(resp, sid, nrc_service_not_in_session)
	}
	match sid {
		0x3E { return s.tester_present(req, req_len, resp) }
		0x10 { return s.session_control(req, req_len, resp) }
		0x11 { return s.ecu_reset(req, req_len, resp) }
		0x22 { return s.read_did(req, req_len, resp) }
		0x27 { return s.security_access(req, req_len, resp) }
		0x14 { return s.clear_dtcs(req, req_len, resp) }
		0x19 { return s.read_dtcs(req, req_len, resp) }
		0x85 { return s.dtc_setting(req, req_len, resp) }
		0x28 { return s.communication_control(req, req_len, resp) }
		0x2E { return s.write_did(req, req_len, resp) }
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
		0x27 { s.security.seed != unsafe { nil } && s.security.key_ok != unsafe { nil } && s.security_levels != 0 }
		0x28 { s.serves_comm_control }
		else { false }
	}
}

// service_sessions: where each service may run. CommunicationControl, SecurityAccess and
// ControlDTCSetting are non-default-session services (a tester must enter extended first, so a
// stray request on a quiet bus cannot silence an ECU, spend its key attempts or freeze its fault
// memory); everything else runs in every session,
// with per-DID gating on top for 0x22/0x2E.
fn service_sessions(sid u8) u8 {
	return match sid {
		0x27, 0x28, 0x85 { in_extended | in_programming }
		else { u8(0) }
	}
}

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

// enter_session changes the active session. EVERY entry relocks security and voids an
// outstanding seed — re-entering the session already active included (ISO 14229-1: security is
// per session instance, and the plan's "every transition, explicit or by S3") — and a return to
// the default session re-enables communication (0x28 state does not survive leaving the
// non-default session).
fn (mut s Server) enter_session(session u8) {
	s.unlocked = 0
	s.sa_level = 0
	s.session = session
	if session == session_default {
		s.normal_tx_off = false
		s.normal_rx_off = false
		s.restore_dtc_setting()
	}
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
	if sub == session_programming && s.no_programming {
		return negative(resp, 0x10, nrc_subfunction_not_supported)
	}
	if req_len != 2 {
		return negative(resp, 0x10, nrc_incorrect_length)
	}
	s.enter_session(sub)
	if unsafe { req[1] } & 0x80 != 0 {
		return 0 // suppressPosRsp on a VALID session: action done, response withheld
	}
	unsafe {
		resp[0] = 0x50
		resp[1] = s.session
		resp[2] = 0x00 // P2_server_max  = 0x0032 (50 ms)
		resp[3] = 0x32
		resp[4] = 0x01 // P2*_server_max = 0x01F4 * 10 ms (5 s)
		resp[5] = 0xF4
	}
	return 6
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
	return if s.sa_attempts == 0 { default_sa_attempts } else { s.sa_attempts }
}

// security_access (0x27). requestSeed (odd subfunction 2L-1) hands out a fresh seed for level L —
// all zeros when L is already unlocked (ISO 14229-1) — and sendKey (2L) checks a key against the
// OUTSTANDING seed of that same level, once: a wrong key spends the seed. After sa_attempts wrong
// keys the answer is exceededNumberOfAttempts and no seed is issued until the lockout delay has
// passed (requiredTimeDelayNotExpired); a reset with wrong keys counted costs the delay too (reset_state).
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
	// an optional securityAccessDataRecord after the subfunction is accepted and ignored
	if s.sa_arm_delay || s.now_us < s.sa_delay_until {
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
	if !s.security.key_ok(s.security.ctx, level, &s.sa_seed[0], unsafe { req + 2 }, seed_len) {
		s.sa_failed[level - 1]++
		if s.sa_failed[level - 1] >= s.sa_max_attempts() {
			s.sa_failed[level - 1] = 0
			s.sa_delay_until = s.now_us + s.sa_delay()
			return negative(resp, 0x27, nrc_exceeded_attempts)
		}
		return negative(resp, 0x27, nrc_invalid_key)
	}
	s.sa_failed[level - 1] = 0
	s.unlocked = level
	if unsafe { req[1] } & 0x80 != 0 {
		return 0
	}
	unsafe {
		resp[0] = 0x67
		resp[1] = req[1]
	}
	return 2
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
// target that opts into the bench key by name (`[[isotp]] security_key = "reference"`).
pub fn reference_key_ok(ctx voidptr, level u8, seed &u8, key &u8, n int) bool {
	for i in 0 .. n {
		if unsafe { key[i] != seed[i] ^ 0xFF } {
			return false
		}
	}
	return true
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

// read_did serves one or MORE DIDs per request (ISO 14229-1 0x22): each supported DID's record
// is appended in request order. A DID that does not exist, or is not readable in the active
// session, is simply not answered; only a request in which NONE is answered gets 0x31. A DID
// that exists but needs a security level not unlocked denies the whole request with 0x33. The
// response must fit the owner's buffer (0x14 otherwise) — checked before anything is written.
fn (mut s Server) read_did(req &u8, req_len int, resp &u8) int {
	if req_len < 3 || (req_len - 1) % 2 != 0 {
		return negative(resp, 0x22, nrc_incorrect_length)
	}
	ndid := (req_len - 1) / 2
	mut total := 1
	mut answered := 0
	for k in 0 .. ndid {
		id := unsafe { (u16(req[1 + 2 * k]) << 8) | u16(req[2 + 2 * k]) }
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
	// record length (0x13).
	if i < 0 || !s.dids[i].writable || !in_mask(s.dids[i].write_sessions, s.session) {
		return negative(resp, 0x2E, nrc_request_out_of_range)
	}
	if s.dids[i].write_security != 0 && s.unlocked != s.dids[i].write_security {
		return negative(resp, 0x2E, nrc_security_access_denied)
	}
	if n > max_did_data {
		return negative(resp, 0x2E, nrc_incorrect_length)
	}
	unsafe {
		for j in 0 .. n {
			s.dids[i].data[j] = req[3 + j]
		}
	}
	s.dids[i].len = u8(n)
	unsafe {
		resp[0] = 0x6E
		resp[1] = req[1]
		resp[2] = req[2]
	}
	return 3
}

// read_dtcs (0x19) — the subfunctions R4 serves (D6): 0x01 reportNumberOfDTCByStatusMask, 0x02
// reportDTCByStatusMask, 0x0A reportSupportedDTC. A DTC matches a mask when (status & mask &
// availability) != 0. The response must fit the owner's buffer (0x14 otherwise), checked before
// anything is written. 0x19 has no suppressPosRsp: bit 7 makes the subfunction unsupported.
fn (mut s Server) read_dtcs(req &u8, req_len int, resp &u8) int {
	if req_len < 2 {
		return negative(resp, 0x19, nrc_incorrect_length)
	}
	sub := unsafe { req[1] }
	if sub != 0x01 && sub != 0x02 && sub != 0x0A {
		return negative(resp, 0x19, nrc_subfunction_not_supported)
	}
	want := if sub == 0x0A { 2 } else { 3 }
	if req_len != want {
		return negative(resp, 0x19, nrc_incorrect_length)
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
	total := 3 + 4 * hits
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
