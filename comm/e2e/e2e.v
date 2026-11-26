module e2e

// End-to-end protection: AUTOSAR E2E Profile 1 (Data ID mode BOTH) and Profile 5 — a CRC and an
// alive counter stamped into a frame on tx and verified on rx. The receiver detects corruption
// (CRC), repetition / a stuck sender (counter not advancing), and — combined with the COM rx
// deadline — loss. No-alloc, transport-agnostic: it operates on the raw frame bytes the bridge
// already has, so it works over any signal transport (last-is-best or, later, queued).
//
// Profile 1 (protect / check; layout per [[frame]].e2e): the alive counter occupies the low
// nibble of byte `counter_pos` and counts 0..14 (15 is not a Profile 1 value); the CRC is byte
// `crc_pos`. The CRC is CRC-8 poly 0x1D with start value 0x00 and NO final XOR — not the
// catalogue's CRC-8/SAE-J1850 (0xFF/0xFF): AUTOSAR's chained Crc_CalculateCRC8 calls cancel
// those — over the 16-bit data_id (low byte, then high) and every frame byte except crc_pos.
//
// Profile 5 (protect_p05 / check_p05): a 3-byte header at byte `offset` — the CRC little-endian
// in `offset` and `offset` + 1, the counter the whole byte after it, counting 0..255. The CRC is
// CRC-16/CCITT-FALSE (poly 0x1021, start 0xFFFF, no final XOR, AUTOSAR's Crc_CalculateCRC16) over
// every frame byte but the CRC's two, then the data_id low byte and high byte.
//
// On a frame composed with SecOC (REQ-E2E-004, the _ex forms), the freshness/MAC windows are
// excluded from either CRC too, a composition rule beyond the profiles themselves. Both profiles
// are pinned by vectors from an independent implementation (autosar-e2e), Profile 1 in
// e2e_test.v and Profile 5 in p05_test.v, the same ones blobly_net's autosar_p01 and
// autosar_p05 are pinned by.

// p01_counter_span: a Profile 1 counter runs 0..14, then wraps to 0.
const p01_counter_span = 15

// p05_counter_span: a Profile 5 counter runs 0..255 (its whole byte), then wraps to 0.
const p05_counter_span = 256

// crc_update is one CRC-8 step, poly 0x1D.
fn crc_update(crc u8, b u8) u8 {
	mut c := crc ^ b
	for _ in 0 .. 8 {
		c = if c & 0x80 != 0 { (c << 1) ^ 0x1D } else { c << 1 }
	}
	return c
}

// compute folds the data id and every covered byte. The two exclusion windows carry
// REQ-E2E-004's composition rule: when a frame also carries SecOC, the E2E CRC must
// cover only the application payload — never the freshness/MAC bytes SecOC stamps
// AFTER the E2E protect, or the receiver's E2E check fails on every authentic frame.
// A zero-length window excludes nothing (the plain single-protection path).
fn compute(data &u8, dlc int, data_id u16, crc_pos int, ex1_pos int, ex1_len int, ex2_pos int, ex2_len int) u8 {
	mut c := crc_update(0x00, u8(data_id)) // start 0x00, fold in the data id (lo, hi)
	c = crc_update(c, u8(data_id >> 8))
	for i in 0 .. dlc {
		if i == crc_pos || excluded(i, ex1_pos, ex1_len, ex2_pos, ex2_len) {
			continue
		}
		c = crc_update(c, unsafe { data[i] })
	}
	return c // no final XOR (Profile 1)
}

// excluded says that byte i lies in one of the two composition windows (a zero-length window
// excludes nothing).
fn excluded(i int, ex1_pos int, ex1_len int, ex2_pos int, ex2_len int) bool {
	return (ex1_len > 0 && i >= ex1_pos && i < ex1_pos + ex1_len)
		|| (ex2_len > 0 && i >= ex2_pos && i < ex2_pos + ex2_len)
}

// crc16_update is one CRC-16/CCITT-FALSE step, poly 0x1021, unreflected.
fn crc16_update(crc u16, b u8) u16 {
	mut c := crc ^ (u16(b) << 8)
	for _ in 0 .. 8 {
		c = if c & 0x8000 != 0 { (c << 1) ^ 0x1021 } else { c << 1 }
	}
	return c
}

// compute_p05 is Profile 5's CRC: start 0xFFFF, every covered byte but the CRC's two at
// `offset` (the bytes before it included), then the data id low byte and high byte; no final
// XOR. The composition windows are compute's.
fn compute_p05(data &u8, dlc int, data_id u16, offset int, ex1_pos int, ex1_len int, ex2_pos int, ex2_len int) u16 {
	mut c := u16(0xFFFF)
	for i in 0 .. dlc {
		if i == offset || i == offset + 1 || excluded(i, ex1_pos, ex1_len, ex2_pos, ex2_len) {
			continue
		}
		c = crc16_update(c, unsafe { data[i] })
	}
	c = crc16_update(c, u8(data_id))
	return crc16_update(c, u8(data_id >> 8))
}

pub struct TxState {
pub mut:
	counter u8
}

// take is the counter value to stamp now, modulo the profile's span, and advances the counter:
// whatever the (public) counter was set to, a frame never carries a value the profile does not
// count (15 on Profile 1).
fn (mut t TxState) take(span int) u8 {
	v := u8(int(t.counter) % span)
	t.counter = u8((int(t.counter) + 1) % span)
	return v
}

// protect stamps the alive counter (low nibble of counter_pos) and the CRC
// (crc_pos) into `data`, then advances the counter.
pub fn (mut t TxState) protect(data &u8, dlc int, data_id u16, crc_pos int, counter_pos int) {
	t.protect_ex(data, dlc, data_id, crc_pos, counter_pos, 0, 0, 0, 0)
}

// protect_ex is protect with the REQ-E2E-004 composition windows: on a frame that also
// carries SecOC, pass (fresh_pos, 1, mac_pos, mac_len) so the CRC never covers the bytes
// SecOC stamps after this call. Order stays: E2E first, then SecOC over everything.
pub fn (mut t TxState) protect_ex(data &u8, dlc int, data_id u16, crc_pos int, counter_pos int, ex1_pos int, ex1_len int, ex2_pos int, ex2_len int) {
	ctr := t.take(p01_counter_span)
	unsafe {
		data[counter_pos] = (data[counter_pos] & 0xF0) | ctr
		data[crc_pos] = compute(data, dlc, data_id, crc_pos, ex1_pos, ex1_len, ex2_pos, ex2_len)
	}
}

// protect_p05 stamps a Profile 5 header at `offset`: the counter (0..255) in byte offset + 2,
// then the CRC low byte first in offset and offset + 1; then advances the counter.
pub fn (mut t TxState) protect_p05(data &u8, dlc int, data_id u16, offset int) {
	t.protect_p05_ex(data, dlc, data_id, offset, 0, 0, 0, 0)
}

// protect_p05_ex is protect_p05 with protect_ex's composition windows (REQ-E2E-004).
pub fn (mut t TxState) protect_p05_ex(data &u8, dlc int, data_id u16, offset int, ex1_pos int, ex1_len int, ex2_pos int, ex2_len int) {
	ctr := t.take(p05_counter_span)
	unsafe {
		data[offset + 2] = ctr
		crc := compute_p05(data, dlc, data_id, offset, ex1_pos, ex1_len, ex2_pos, ex2_len)
		data[offset] = u8(crc)
		data[offset + 1] = u8(crc >> 8)
	}
}

pub enum Status {
	ok        // CRC valid, counter advanced by exactly 1
	crc_error // corrupted: a CRC mismatch, or a counter no Profile 1 sender produces (15)
	repeated  // counter did not advance — duplicate / stuck sender
	lost      // CRC valid but the counter skipped — one or more frames were lost
}

// usable reports whether the frame's data should be consumed: ok and lost are both
// valid, fresh frames (lost just notes a gap before it); repeated/crc_error are not.
pub fn (s Status) usable() bool {
	return s == .ok || s == .lost
}

pub struct RxState {
pub mut:
	last    u8
	started bool
	// frames the counter showed not received INTACT, summed over every `lost` gap (delta - 1 each;
	// a gap of a whole span or more aliases: 15 on the Profile 1 counter, 256 on Profile 5's). A frame that failed its CRC counts here
	// too, as in AUTOSAR E2E: its counter byte cannot be trusted, so no rule can tell which gap
	// positions it filled. Monotonic and wrapping: a reader diffs it.
	lost_frames u32
	// The E2E-owned reception timeout (REQ-E2E-002): no VALID message — ok or lost; a repeat or a
	// CRC error does not count — within timeout_us is total loss of the sender, detected inside
	// the E2E mechanism rather than by the QM COM deadline. 0 = off. The owner arms it at start
	// (arm), reports each usable frame (on_valid) and polls expired. It deliberately mirrors
	// com.RxState's deadline rather than sharing it: REQ-E2E-002 keeps the ASIL-B loss check
	// inside the E2E mechanism, independent of the QM COM monitor.
	timeout_us  u64
	valid_us    u64
	armed       bool
	timedout    bool
}

// arm starts the timeout with no valid message yet — at start, so a sender absent since then
// times out too — and restarts it (after a commanded reception pause).
pub fn (mut r RxState) arm(now u64) {
	r.valid_us = now
	r.armed = true
	r.timedout = false
}

// on_valid records a usable (ok / lost) message at `now`.
pub fn (mut r RxState) on_valid(now u64) {
	r.arm(now)
}

// expired returns true exactly once, when no valid message arrived for timeout_us.
pub fn (mut r RxState) expired(now u64) bool {
	if r.timeout_us == 0 || !r.armed || r.timedout {
		return false
	}
	if now - r.valid_us > r.timeout_us {
		r.timedout = true
		return true
	}
	return false
}

// RxVerdict is what a receiver publishes for one checked frame (receive).
pub enum RxVerdict {
	none      // a repeat: publish nothing, the last value stands
	ok        // a usable frame: publish its value
	timeout   // a usable frame that arrived after the timeout ran out unseen: value withheld
	integrity // a corrupt frame: publish the failure, value withheld
}

// receive is the receive-side rule for one frame `check` has judged (REQ-E2E-002): a usable frame
// (ok or lost) re-arms the sender-loss timeout and is published — as a timeout, value withheld,
// when the timeout ran out before the caller polled `expired`; a corrupt frame is published as
// an integrity failure and restarts only a timeout that has already fired, so corrupt frames can
// never keep a dead sender looking alive (the caller's `expired` poll still reports one); a
// repeat publishes nothing. ONE rule for every receive path that applies it.
pub fn (mut r RxState) receive(now u64, st Status) RxVerdict {
	return r.receive_ex(now, st, false)
}

// receive_ex is receive with the deadline SUSPENDED (`suspended`): while a commanded reception
// pause (UDS 0x28) is still latched, its restart has not run, so the deadline is the stale
// pre-silence one — a usable frame is never judged late against it. The CAN bridge passes its
// 0x28 latch; others pass false.
pub fn (mut r RxState) receive_ex(now u64, st Status, suspended bool) RxVerdict {
	if st.usable() {
		late := !suspended && r.expired(now)
		r.on_valid(now)
		return if late { RxVerdict.timeout } else { RxVerdict.ok }
	}
	if st == .crc_error {
		// only a timeout that has already FIRED restarts on a corrupt frame (the integrity is then
		// the newer fact). A deadline that has passed unpolled is left for the caller's poll to
		// report: re-arming it here would let a sender that only ever sends corrupt frames, at the
		// receiver's own cadence, never be reported lost at all (REQ-E2E-002)
		if r.timedout {
			r.arm(now)
		}
		return .integrity
	}
	return .none
}

// check verifies the CRC and the counter progression (delta 0 = repeated,
// 1 = ok, >1 = lost; modulo 15). It resyncs to the received counter except on a CRC error.
// A counter of 15 is refused like a CRC error: no Profile 1 sender produces it, so the frame is
// not one to trust, and it says nothing about the sequence.
pub fn (mut r RxState) check(data &u8, dlc int, data_id u16, crc_pos int, counter_pos int) Status {
	return r.check_ex(data, dlc, data_id, crc_pos, counter_pos, 0, 0, 0, 0)
}

// check_ex is check with the same composition windows as protect_ex — the receiver
// must exclude exactly what the transmitter excluded (SecOC verified first, per the
// symmetric order REQ-E2E-004 defines).
pub fn (mut r RxState) check_ex(data &u8, dlc int, data_id u16, crc_pos int, counter_pos int, ex1_pos int, ex1_len int, ex2_pos int, ex2_len int) Status {
	if unsafe { data[crc_pos] } != compute(data, dlc, data_id, crc_pos, ex1_pos, ex1_len, ex2_pos, ex2_len) {
		return .crc_error
	}
	ctr := unsafe { data[counter_pos] } & 0x0F
	if ctr >= p01_counter_span {
		return .crc_error
	}
	return r.sequence(ctr, p01_counter_span)
}

// check_p05 verifies a Profile 5 header at `offset` — the CRC, then the counter's progression
// modulo 256, by check's rule (every byte value is a Profile 5 counter).
pub fn (mut r RxState) check_p05(data &u8, dlc int, data_id u16, offset int) Status {
	return r.check_p05_ex(data, dlc, data_id, offset, 0, 0, 0, 0)
}

// check_p05_ex is check_p05 with check_ex's composition windows (REQ-E2E-004).
pub fn (mut r RxState) check_p05_ex(data &u8, dlc int, data_id u16, offset int, ex1_pos int, ex1_len int, ex2_pos int, ex2_len int) Status {
	got := u16(unsafe { data[offset] }) | (u16(unsafe { data[offset + 1] }) << 8)
	if got != compute_p05(data, dlc, data_id, offset, ex1_pos, ex1_len, ex2_pos, ex2_len) {
		return .crc_error
	}
	return r.sequence(unsafe { data[offset + 2] }, p05_counter_span)
}

// sequence judges a counter whose frame passed its CRC against the last one, modulo the
// profile's `span` (delta 0 = repeated, 1 = ok, >1 = lost, each gap counted in lost_frames), and
// makes it the reference.
fn (mut r RxState) sequence(ctr u8, span int) Status {
	mut st := Status.ok
	if r.started {
		delta := (int(ctr) + span - int(r.last)) % span
		st = if delta == 0 { Status.repeated } else if delta > 1 { Status.lost } else { Status.ok }
		if delta > 1 {
			r.lost_frames += u32(delta - 1)
		}
	}
	r.last = ctr
	r.started = true
	return st
}
