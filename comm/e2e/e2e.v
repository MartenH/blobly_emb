module e2e

// End-to-end protection (ISO 26262 / AUTOSAR-E2E style, lean): an 8-bit CRC and a
// 4-bit alive counter stamped into a frame on tx and verified on rx. The receiver
// detects corruption (CRC), repetition / a stuck sender (counter not advancing),
// and — combined with the COM rx deadline — loss. No-alloc, transport-agnostic:
// it operates on the raw frame bytes the bridge already has, so it works over any
// signal transport (last-is-best or, later, queued).
//
// Layout (configured per [[frame]].e2e): the alive counter occupies the low nibble
// of byte `counter_pos`; the CRC is byte `crc_pos`; the CRC covers the 16-bit
// data_id + every frame byte except crc_pos itself.

// crc_update is the SAE J1850 CRC-8 step (poly 0x1D), as AUTOSAR E2E P01/P02 use.
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
	mut c := crc_update(0xFF, u8(data_id)) // init 0xFF, fold in the data id (lo, hi)
	c = crc_update(c, u8(data_id >> 8))
	for i in 0 .. dlc {
		if i == crc_pos {
			continue
		}
		if ex1_len > 0 && i >= ex1_pos && i < ex1_pos + ex1_len {
			continue
		}
		if ex2_len > 0 && i >= ex2_pos && i < ex2_pos + ex2_len {
			continue
		}
		c = crc_update(c, unsafe { data[i] })
	}
	return c ^ 0xFF // final xor
}

pub struct TxState {
pub mut:
	counter u8
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
	unsafe {
		data[counter_pos] = (data[counter_pos] & 0xF0) | (t.counter & 0x0F)
		data[crc_pos] = compute(data, dlc, data_id, crc_pos, ex1_pos, ex1_len, ex2_pos, ex2_len)
	}
	t.counter = (t.counter + 1) & 0x0F
}

pub enum Status {
	ok        // CRC valid, counter advanced by exactly 1
	crc_error // corrupted (CRC mismatch)
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
}

// check verifies the CRC and the counter progression (delta 0 = repeated,
// 1 = ok, >1 = lost). It resyncs to the received counter except on a CRC error.
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
	mut st := Status.ok
	if r.started {
		delta := (ctr - r.last) & 0x0F
		st = if delta == 0 { Status.repeated } else if delta > 1 { Status.lost } else { Status.ok }
	}
	r.last = ctr
	r.started = true
	return st
}
