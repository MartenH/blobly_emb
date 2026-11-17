module uds

// InputOutputControlByIdentifier (0x2F, ISO 14229-1) on a live signal's DID (docs/diagnostics.md
// §3.1 "Input/output control"). The server holds what a tester asked for; the owner applies it
// WHERE IT ENCODES the signal into its frame (io_held, or io_on and io_published), on the thread
// that serves this server, so no FB ever sees it. The DID is the one 0x22 reads, and the value is
// the signal's value field at its width, big-endian, as a live DID reads it.
//
// Parameters: 00 returnControlToECU (served for every control; dropped like any request while an
// answer is owed, pending.v), 01 resetToDefault, 02 freezeCurrentState,
// 03 shortTermAdjustment (each served where the control's `params` says). No controlEnableMask:
// a controlled signal has one field, so a request carrying one is the wrong length (0x13).

// max_ios: the controls one server holds.
pub const max_ios = 4

pub const io_return_control = u8(0x00)
pub const io_reset_to_default = u8(0x01)
pub const io_freeze_current_state = u8(0x02)
pub const io_short_term_adjustment = u8(0x03)

// IoControl is one controlled DID. Configuration, from generation: the value's width in bytes (1,
// 2 or 4) and sign, its range [lo, hi] (the DBC's, converted to the field's values) and its
// default (the signal's initial value, inside the range), the parameters served (bit p for
// parameter p; 00 is served for every control), the sessions (an in_* mask, never 0 from generation) and the
// 0x27 level it needs (0 = none). Run time — zero is the ECU in control: the parameter in force
// (`held`, 0 = none) and its value, and the function block's value as the owner last noted it.
pub struct IoControl {
pub mut:
	did      u16
	width    u8
	signed   bool
	lo       i64
	hi       i64
	dflt     i64
	params   u8
	sessions u8
	security u8
	held     u8
	value    i64
	fb       i64
	fb_have  bool
}

// find_io: the control table index of `did`, or -1.
fn (s &Server) find_io(did u16) int {
	for i in 0 .. s.nio {
		if i >= max_ios {
			break
		}
		if s.ios[i].did == did {
			return i
		}
	}
	return -1
}

// io_control (0x2F). After the service row (dispatch: 0x11, 0x7F, the row's 0x33), in ISO 14229-1's
// order: shorter than 4 bytes 0x13; a DID with no control, or outside its sessions, 0x31; its level
// not unlocked 0x33; the total length — 4 for 00/01/02, 4 plus the width for 03, served or not —
// 0x13; a parameter above 03 or not served 0x31; a controlState outside [lo, hi] 0x31; the
// application's refusal (io_ok, never asked for 00) 0x22; an answer the buffer cannot hold 0x14.
// The positive answer carries the DID, the parameter and the value published from then on
// (io_published).
fn (mut s Server) io_control(req &u8, req_len int, resp &u8) int {
	if req_len < 4 {
		return negative(resp, 0x2F, nrc_incorrect_length)
	}
	did := unsafe { (u16(req[1]) << 8) | u16(req[2]) }
	k := s.find_io(did)
	if k < 0 || !in_mask(s.ios[k].sessions, s.session) {
		return negative(resp, 0x2F, nrc_request_out_of_range)
	}
	c := s.ios[k]
	if c.security != 0 && s.unlocked != c.security {
		return negative(resp, 0x2F, nrc_security_access_denied)
	}
	p := unsafe { req[3] }
	// a parameter ISO defines has a known length whether or not this DID serves it; a reserved one
	// (above 03) has none, so it goes to the parameter check
	if p <= io_short_term_adjustment {
		want := if p == io_short_term_adjustment { 4 + int(c.width) } else { 4 }
		if req_len != want {
			return negative(resp, 0x2F, nrc_incorrect_length)
		}
	}
	if p > io_short_term_adjustment || (p != io_return_control && c.params & (u8(1) << p) == 0) {
		return negative(resp, 0x2F, nrc_request_out_of_range)
	}
	mut v := i64(0)
	if p == io_short_term_adjustment {
		v = io_decode(unsafe { req + 4 }, c.width, c.signed)
		if v < c.lo || v > c.hi {
			return negative(resp, 0x2F, nrc_request_out_of_range)
		}
	} else if p == io_freeze_current_state {
		v = s.io_published(k) // what is being published now
	} else if p == io_reset_to_default {
		v = c.dflt
	}
	if p != io_return_control && s.io_ok != unsafe { nil } && !s.io_ok(did, p) {
		return negative(resp, 0x2F, nrc_conditions_not_correct)
	}
	if 4 + int(c.width) > s.cap() {
		return negative(resp, 0x2F, nrc_response_too_long)
	}
	if p == io_return_control {
		s.ios[k].held = 0
	} else {
		s.ios[k].held = p
		s.ios[k].value = v
	}
	pubv := s.io_published(k)
	w := int(c.width)
	unsafe {
		resp[0] = 0x6F
		resp[1] = req[1]
		resp[2] = req[2]
		resp[3] = p
		for i in 0 .. w {
			resp[4 + i] = u8(pubv >> (8 * (w - 1 - i)))
		}
	}
	return 4 + w
}

// io_decode: `width` big-endian bytes at `b` as a value, sign-extended when `signed`.
fn io_decode(b &u8, width u8, signed bool) i64 {
	mut u := u64(0)
	for i in 0 .. int(width) {
		u = (u << 8) | u64(unsafe { b[i] })
	}
	if signed && width > 0 && width < 8 {
		top := u64(1) << (8 * int(width) - 1)
		if u & top != 0 {
			return i64(u | ~((top << 1) - 1))
		}
	}
	return i64(u)
}

fn io_clamp(v i64, lo i64, hi i64) i64 {
	return if v < lo {
		lo
	} else if v > hi {
		hi
	} else {
		v
	}
}

// io_held: whether control `i` is in force, and the value the owner publishes in place of the
// function block's while it is. The owner asks it where it encodes the signal.
pub fn (s &Server) io_held(i int) (bool, i64) {
	if !s.io_on(i) {
		return false, 0
	}
	return true, s.ios[i].value
}

// io_on: whether control `i` is in force — io_held's first answer, for an owner that encodes where
// it can declare no name of its own (the host bridge, whose locals are its signals' names): it asks
// this, and io_published for the value, which under control is the control's.
pub fn (s &Server) io_on(i int) bool {
	return i >= 0 && i < max_ios && i < s.nio && s.ios[i].held != 0
}

// io_published: the value control `i`'s signal is published with — THE one rule, which 02 freezes,
// the 0x6F answer carries and every live DID of the signal reads. Under control its value; else
// the function block's as last noted, held to [lo, hi] as the encoder saturates it (generation
// makes the range's ends and every whole value inside it exact on the DBC's grid, so this is the
// value the frame carries); else, before the function block has published one, the default (the
// frame's initial value).
pub fn (s &Server) io_published(i int) i64 {
	if i < 0 || i >= max_ios || i >= s.nio {
		return 0
	}
	c := s.ios[i]
	return if c.held != 0 {
		c.value
	} else if c.fb_have {
		io_clamp(c.fb, c.lo, c.hi)
	} else {
		c.dflt
	}
}

// io_note: the function block's current value of control `i`'s signal and whether it has
// published one — the owner's refresh before every dispatch, so a 0x2F 02 freezes the value
// published at that moment.
pub fn (mut s Server) io_note(i int, fb i64, have bool) {
	if i < 0 || i >= max_ios || i >= s.nio {
		return
	}
	s.ios[i].fb = fb
	s.ios[i].fb_have = have
}

// relock: security level `level` ends without a session entry (comm/diag: the network tester that
// held it disconnected) — the unlock is cleared where it is that level, every control gated on it is
// returned and every routine gated on it asked to stop. 0 relocks nothing. The one way an unlock is
// dropped outside a session entry, so nothing it gated outlives it.
pub fn (mut s Server) relock(level u8) {
	s.end_levels(level, false)
}

// end_levels: the gates a relock ends (relock_ends) — level `level` (`others` false), or every level
// but `level` (`others` true: a key unlocked `level`, and 0x27 holds one): the unlock where it is
// one of them, every control gated on one returned, every routine gated on one asked to stop
fn (mut s Server) end_levels(level u8, others bool) {
	if relock_ends(s.unlocked, level, others) {
		s.unlocked = 0
	}
	s.io_return_where(level, others, 0)
	s.stop_relocked_routines(level, others)
}

// relock_ends: whether a gate needing level `sec` (0 = none) ends when level `level` is relocked
// (`others` false; 0 relocks nothing) or every level but `level` is (`others` true) — the one rule
// for the unlock, the controls and the routines
fn relock_ends(sec u8, level u8, others bool) bool {
	return if others { sec != 0 && sec != level } else { level != 0 && sec == level }
}

// io_ends: whether control `c` goes back to the ECU — on a session entry (`session` != 0) a return
// to default returns every control, and any other entry, re-entering the active session included,
// relocks security, so a control that needs a level is returned, and so is one whose sessions leave
// out the new session; else (`session` 0) when a relock ends its level (relock_ends)
fn io_ends(c &IoControl, level u8, others bool, session u8) bool {
	if session != 0 {
		return session == session_default || c.security != 0 || !in_mask(c.sessions, session)
	}
	return relock_ends(c.security, level, others)
}

// io_return_where: every control io_ends names back to the ECU — a relock (end_levels), a session
// entry (enter_session), a reset (reset_state, as a return to the default session)
fn (mut s Server) io_return_where(level u8, others bool, session u8) {
	for i in 0 .. s.nio {
		if i >= max_ios {
			break
		}
		if io_ends(&s.ios[i], level, others, session) {
			s.ios[i].held = 0
		}
	}
}
