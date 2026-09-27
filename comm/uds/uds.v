module uds

// UDS (ISO 14229-1) server, no-alloc and transport-agnostic. It sits above ISO-TP (or DoIP):
// the owner hands it a reassembled request and ships the response it produces. Table-driven so
// the protocol logic is shared and unit-tested; the DIDs (and any live-signal refresh) are
// filled in by the generated bridge (docs/diagnostics.md §3.1).
//
// Services: 0x10 DiagnosticSessionControl, 0x11 ECUReset, 0x22 ReadDataByIdentifier (several
// DIDs per request), 0x28 CommunicationControl, 0x2E WriteDataByIdentifier, 0x3E TesterPresent.
// Anything else -> 0x11 serviceNotSupported.
//
// Negative responses follow ISO 14229-1's evaluation order. Every service: supported (0x11) →
// allowed in the active session (0x7F) → minimum length (0x13); then, for a subfunction service:
// subfunction supported (0x12) → exact length (0x13) → conditions / range. The DID services follow
// their own flow: 0x22 — length, then each DID's support and session (0x31 when none answers),
// then security (0x33), then the response size (0x14); 0x2E — length, then the DID's support,
// writability and session (0x31), then security (0x33), then the record length (0x13). A FUNCTIONAL request never answers 0x11, 0x12, 0x31, 0x7E or 0x7F
// (handle_functional) — a broadcast into an unsupported or gated service stays silent.

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
pub const nrc_subfunction_not_in_session = u8(0x7E)
pub const nrc_service_not_in_session = u8(0x7F)

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

// note_request records diagnostic activity at the current tick without serving anything — for
// an owner that accepts a request now and serves it later (a queued functional request), so the
// wait cannot let S3 expire the session the request was meant to keep alive.
pub fn (mut s Server) note_request() {
	s.last_rx_us = s.now_us
	s.rx_seen = true
}

// reset_state returns the diagnostic state to power-on: default session, security locked,
// communication enabled, no pending reset. DIDs are untouched.
pub fn (mut s Server) reset_state() {
	s.session = session_default
	s.unlocked = 0
	s.normal_tx_off = false
	s.normal_rx_off = false
	s.reset_req = 0
	s.last_rx_us = 0
	s.rx_seen = false
}

// tick advances the server's clock and applies S3: a non-default session with no request for
// S3 returns to default (ISO 14229-2). Call once per owner pass, before handling requests.
pub fn (mut s Server) tick(now_us u64) {
	s.now_us = now_us
	if s.session == session_default || s.session == 0 || !s.rx_seen {
		return
	}
	s3 := if s.s3_us == 0 { default_s3_us } else { s.s3_us }
	if now_us - s.last_rx_us > s3 {
		s.enter_session(session_default)
	}
}

// tx_enabled / rx_enabled: CommunicationControl's effect on normal communication messages, for
// the owner to gate its application frames on.
pub fn (s Server) tx_enabled() bool {
	return !s.normal_tx_off
}

pub fn (s Server) rx_enabled() bool {
	return !s.normal_rx_off
}

// handle dispatches one PHYSICALLY addressed UDS request (req[0..req_len]) and writes the
// response into resp, returning its length (0 = no response, e.g. suppressed).
pub fn (mut s Server) handle(req &u8, req_len int, resp &u8) int {
	return s.dispatch(req, req_len, resp, true)
}

// handle_functional dispatches a FUNCTIONALLY addressed request: identical, except the
// negative responses ISO 14229-1 forbids for functional requests are withheld.
pub fn (mut s Server) handle_functional(req &u8, req_len int, resp &u8) int {
	return s.functional(req, req_len, resp, true)
}

// handle_functional_noted serves a functional request whose ARRIVAL was already recorded with
// note_request() — an owner that queued it. S3 keeps that arrival time: stamping again at serve
// time would stretch the session by however long the request waited.
pub fn (mut s Server) handle_functional_noted(req &u8, req_len int, resp &u8) int {
	return s.functional(req, req_len, resp, false)
}

fn (mut s Server) functional(req &u8, req_len int, resp &u8, stamp bool) int {
	n := s.dispatch(req, req_len, resp, stamp)
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

fn (mut s Server) dispatch(req &u8, req_len int, resp &u8, stamp bool) int {
	if req_len < 1 || s.resp_cap < 0 {
		return 0
	}
	if stamp {
		s.last_rx_us = s.now_us // any request keeps the session alive (S3)
		s.rx_seen = true
	}
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
		0x28 { return s.communication_control(req, req_len, resp) }
		0x2E { return s.write_did(req, req_len, resp) }
		else { return negative(resp, sid, nrc_service_not_supported) }
	}
}

// service_supported: the SIDs dispatch() serves — kept in step with its match by
// test_every_supported_service_dispatches, which fails if a SID is listed here and not handled.
fn (s Server) service_supported(sid u8) bool {
	return match sid {
		0x10, 0x22, 0x2E, 0x3E { true }
		0x11 { s.serves_reset }
		0x28 { s.serves_comm_control }
		else { false }
	}
}

// service_sessions: where each service may run. CommunicationControl is a non-default-session
// service (a tester must enter extended first, so a stray request on a quiet bus cannot silence
// an ECU); everything else runs in every session, with per-DID gating on top for 0x22/0x2E.
fn service_sessions(sid u8) u8 {
	return match sid {
		0x28 { in_extended | in_programming }
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

// enter_session changes the active session. Any transition relocks security (ISO 14229-1
// 0x27), and a return to the default session re-enables communication (0x28 state does not
// survive leaving the non-default session).
fn (mut s Server) enter_session(session u8) {
	if session != s.session {
		s.unlocked = 0
	}
	s.session = session
	if session == session_default {
		s.normal_tx_off = false
		s.normal_rx_off = false
	}
}

fn (s Server) cap() int {
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

// find_did: the table index of `id`, or -1.
fn (s Server) find_did(id u16) int {
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

fn negative(resp &u8, sid u8, nrc u8) int {
	unsafe {
		resp[0] = 0x7F
		resp[1] = sid
		resp[2] = nrc
	}
	return 3
}
