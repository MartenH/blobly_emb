module e2e

// @verifies SYS-REQ-SAFE-001 REQ-E2E-001 REQ-E2E-002 REQ-E2E-003
// (corruption -> not delivered; repeat + skipped-sequence via the counter — the
//  total-loss-by-timeout leg of E2E-002 is comm/com's rx deadline; protect-on-transmit
//  incl. counter advance and 15->0 wrap.)

const id = u16(0x0123)
const crc_pos = 1
const ctr_pos = 2

fn test_protect_then_check_roundtrip() {
	mut tx := TxState{}
	mut rx := RxState{}
	mut f := [8]u8{}
	f[0] = 0xA5 // some signal payload
	tx.protect(&f[0], 8, id, crc_pos, ctr_pos)
	assert f[ctr_pos] & 0x0F == 0 // first counter value
	assert rx.check(&f[0], 8, id, crc_pos, ctr_pos) == .ok

	// next frame: counter advances, still ok
	f[0] = 0xA6
	tx.protect(&f[0], 8, id, crc_pos, ctr_pos)
	assert f[ctr_pos] & 0x0F == 1
	assert rx.check(&f[0], 8, id, crc_pos, ctr_pos) == .ok
}

fn test_corruption_detected() {
	mut tx := TxState{}
	mut rx := RxState{}
	mut f := [8]u8{}
	f[0] = 0x42
	tx.protect(&f[0], 8, id, crc_pos, ctr_pos)
	f[0] ^= 0xFF // flip the payload after protection
	assert rx.check(&f[0], 8, id, crc_pos, ctr_pos) == .crc_error
}

fn test_repetition_detected() {
	mut tx := TxState{}
	mut rx := RxState{}
	mut f := [8]u8{}
	tx.protect(&f[0], 8, id, crc_pos, ctr_pos)
	assert rx.check(&f[0], 8, id, crc_pos, ctr_pos) == .ok
	// re-deliver the SAME frame (counter unchanged) -> repeated, and not usable
	r := rx.check(&f[0], 8, id, crc_pos, ctr_pos)
	assert r == .repeated
	assert !r.usable()
}

fn test_loss_detected() {
	mut tx := TxState{}
	mut rx := RxState{}
	mut f := [8]u8{}
	tx.protect(&f[0], 8, id, crc_pos, ctr_pos) // counter 0
	assert rx.check(&f[0], 8, id, crc_pos, ctr_pos) == .ok
	tx.protect(&f[0], 8, id, crc_pos, ctr_pos) // counter 1 — NOT delivered (lost)
	tx.protect(&f[0], 8, id, crc_pos, ctr_pos) // counter 2 — arrives
	s := rx.check(&f[0], 8, id, crc_pos, ctr_pos)
	assert s == .lost // the skip is detected
	assert s.usable() // but the frame itself is valid + fresh, so still consumed
}

fn test_wrong_data_id_fails() {
	mut tx := TxState{}
	mut rx := RxState{}
	mut f := [8]u8{}
	tx.protect(&f[0], 8, id, crc_pos, ctr_pos)
	// a receiver expecting a different data id (wrong source) rejects it
	assert rx.check(&f[0], 8, u16(0x4444), crc_pos, ctr_pos) == .crc_error
}

fn test_counter_wraps_15_to_0() {
	mut tx := TxState{}
	mut rx := RxState{}
	mut f := [8]u8{}
	for _ in 0 .. 17 { // run past the 4-bit wrap
		tx.protect(&f[0], 8, id, crc_pos, ctr_pos)
		assert rx.check(&f[0], 8, id, crc_pos, ctr_pos) == .ok
	}
}
