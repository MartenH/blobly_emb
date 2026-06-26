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

fn compute(data &u8, dlc int, data_id u16, crc_pos int) u8 {
	mut c := crc_update(0xFF, u8(data_id)) // init 0xFF, fold in the data id (lo, hi)
	c = crc_update(c, u8(data_id >> 8))
	for i in 0 .. dlc {
		if i != crc_pos {
			c = crc_update(c, unsafe { data[i] })
		}
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
	unsafe {
		data[counter_pos] = (data[counter_pos] & 0xF0) | (t.counter & 0x0F)
		data[crc_pos] = compute(data, dlc, data_id, crc_pos)
	}
	t.counter = (t.counter + 1) & 0x0F
}

pub enum Status {
	ok
	crc_error // corrupted (CRC mismatch)
	repeated  // counter did not advance — duplicate / stuck sender
}

pub struct RxState {
pub mut:
	last    u8
	started bool
}

// check verifies the CRC and the counter progression.
pub fn (mut r RxState) check(data &u8, dlc int, data_id u16, crc_pos int, counter_pos int) Status {
	if unsafe { data[crc_pos] } != compute(data, dlc, data_id, crc_pos) {
		return .crc_error
	}
	ctr := unsafe { data[counter_pos] } & 0x0F
	mut st := Status.ok
	if r.started && ((ctr - r.last) & 0x0F) == 0 {
		st = .repeated
	}
	r.last = ctr
	r.started = true
	return st
}
