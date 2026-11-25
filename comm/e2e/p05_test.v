module e2e

import comm.secoc

// @verifies REQ-E2E-001 REQ-E2E-003 REQ-E2E-004
// AUTOSAR E2E Profile 5: the CRC pinned by vectors from an INDEPENDENT implementation —
// autosar-e2e 1.0.0, the table blobly_net's autosar_p05 is pinned by (its sut/e2e_oracle.py
// regenerates them) — the counter judged over 0..255, and the SecOC composition windows.
//
// Two layouts: the header at byte 0 of an 8-byte frame (Data ID 0x1234), and at byte 3 of a
// 12-byte CAN-FD frame (Data ID 0x0BEE), so the CRC covers bytes on both sides of itself. The CRC
// of each frame at the counters below.
const p05_counters = [0, 1, 2, 3, 127, 128, 254, 255]
const p05_vectors_a = [u16(0x0821), 0x4FF2, 0x8787, 0xC054, 0x61EF, 0xF5A0, 0xDBBD, 0x9C6E]
const p05_vectors_b = [u16(0x8D87), 0x66A4, 0x4BE0, 0xA0C3, 0xBE08, 0x3235, 0xEA99, 0x01BA]
const p05_base_a = [u8(0), 0, 0, 0x11, 0x22, 0x33, 0x44, 0x55]
const p05_base_b = [u8(0xE8), 0x03, 0x5A, 0, 0, 0, 0x10, 0x20, 0x30, 0x40, 0x50, 0x60]
const p05_id_b = u16(0x0BEE)
const p05_sec_id = u16(0x0123)

fn test_crc16_is_ccitt_false() {
	mut c := u16(0xFFFF)
	for b in '123456789'.bytes() {
		c = crc16_update(c, b)
	}
	assert c == 0x29B1 // the catalogue check value
}

fn test_crc_is_autosar_profile_5() {
	for layout in [[0x1234, 0], [0x0BEE, 3]] {
		base := if layout[1] == 0 { p05_base_a } else { p05_base_b }
		want := if layout[1] == 0 { p05_vectors_a } else { p05_vectors_b }
		at := layout[1]
		for i, ctr in p05_counters {
			mut tx := TxState{
				counter: u8(ctr)
			}
			f := stamp(mut tx, base, u16(layout[0]), at)
			assert f[at + 2] == u8(ctr)
			got := u16(f[at]) | u16(f[at + 1]) << 8
			assert got == want[i], 'layout ${layout} counter ${ctr}: 0x${got:04X}, the reference says 0x${want[i]:04X}'
			assert tx.counter == u8((ctr + 1) % 256)
			// and a receiver accepts the reference frame as a first frame
			mut rx := RxState{}
			assert rx.check_p05(&f[0], f.len, u16(layout[0]), at) == .ok
		}
	}
}

fn p05_frame(mut tx TxState) []u8 {
	return stamp(mut tx, p05_base_b, p05_id_b, 3)
}

// stamp is `base` protected by `tx` with the header at `at`.
fn stamp(mut tx TxState, base []u8, id u16, at int) []u8 {
	mut f := base.clone()
	unsafe { tx.protect_p05(&f[0], f.len, id, at) }
	return f
}

// ck is rx's verdict on frame f with the header at `at`.
fn ck(mut rx RxState, f []u8, id u16, at int) Status {
	return rx.check_p05(&f[0], f.len, id, at)
}

fn test_p05_counter_is_judged_over_0_to_255() {
	mut tx := TxState{}
	mut rx := RxState{}
	for n in 0 .. 300 { // across a wrap: 255 -> 0 is the next counter, not a skip
		f := p05_frame(mut tx)
		assert f[5] == u8(n % 256)
		assert ck(mut rx, f, p05_id_b, 3) == .ok, 'frame ${n}'
	}
	same := p05_frame(mut tx) // 300 % 256 = 44
	assert ck(mut rx, same, p05_id_b, 3) == .ok
	assert ck(mut rx, same, p05_id_b, 3) == .repeated
	p05_frame(mut tx) // 45 lost
	p05_frame(mut tx) // 46 lost
	skip := p05_frame(mut tx)
	assert ck(mut rx, skip, p05_id_b, 3) == .lost
	assert rx.lost_frames == 2
	// a gap of 200 is 199 frames lost on a counter of 256, where Profile 1's 15 would alias it
	for _ in 0 .. 199 {
		p05_frame(mut tx)
	}
	far := p05_frame(mut tx)
	assert ck(mut rx, far, p05_id_b, 3) == .lost
	assert rx.lost_frames == 2 + 199
}

fn test_p05_corruption_is_detected() {
	mut tx := TxState{}
	mut bad := p05_frame(mut tx)
	bad[11] ^= 0x80 // a byte after the header
	mut rx := RxState{}
	assert ck(mut rx, bad, p05_id_b, 3) == .crc_error
	assert !rx.started, 'a corrupt frame must not become the sequence reference'
	mut hi := p05_frame(mut tx)
	hi[4] ^= 0x01 // the CRC's HIGH byte alone
	assert ck(mut rx, hi, p05_id_b, 3) == .crc_error
	mut before := p05_frame(mut tx)
	before[0] ^= 0x01 // a byte before the header
	assert ck(mut rx, before, p05_id_b, 3) == .crc_error
	mut ctr := p05_frame(mut tx)
	ctr[5] ^= 0x01 // the counter is covered too
	assert ck(mut rx, ctr, p05_id_b, 3) == .crc_error
	good := p05_frame(mut tx)
	assert ck(mut rx, good, u16(0x0BEF), 3) == .crc_error // another Data ID
	assert ck(mut rx, good, p05_id_b, 3) == .ok
}

// the composition windows of REQ-E2E-004 work on Profile 5 as on Profile 1: the CRC never covers
// the SecOC freshness/MAC bytes stamped after it
fn test_p05_composes_with_secoc() {
	key := secoc.new_key([16]u8{init: u8(7)})
	// header at 0 (CRC 0-1, counter 2), payload 3-4, freshness 5, MAC 6-7
	mut etx := TxState{}
	mut stx := secoc.TxState{}
	mut erx := RxState{}
	mut srx := secoc.RxState{}
	for seed in u8(1) .. u8(6) {
		mut d := [8]u8{}
		d[3] = seed
		d[4] = 0x22
		etx.protect_p05_ex(&d[0], 8, p05_sec_id, 0, 5, 1, 6, 2)
		stx.protect(&key, &d[0], 8, p05_sec_id, 5, 6, 2)
		assert srx.verify(&key, &d[0], 8, p05_sec_id, 5, 6, 2) == .ok
		assert erx.check_p05_ex(&d[0], 8, p05_sec_id, 0, 5, 1, 6, 2) == .ok
		// SecOC's own bytes are not E2E's to judge, and a payload byte is
		mut m := d
		m[5]++
		m[7] ^= 0xFF
		mut erx2 := RxState{}
		assert erx2.check_p05_ex(&m[0], 8, p05_sec_id, 0, 5, 1, 6, 2) == .ok
		m[3] ^= 0x01
		mut erx3 := RxState{}
		assert erx3.check_p05_ex(&m[0], 8, p05_sec_id, 0, 5, 1, 6, 2) == .crc_error
	}
	// without the windows, the SecOC stamp breaks the CRC (what the windows are for)
	mut d := [8]u8{}
	etx.protect_p05(&d[0], 8, p05_sec_id, 0)
	stx.protect(&key, &d[0], 8, p05_sec_id, 5, 6, 2)
	mut erx4 := RxState{}
	assert erx4.check_p05(&d[0], 8, p05_sec_id, 0) == .crc_error
}
