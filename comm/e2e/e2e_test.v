module e2e

// @verifies SYS-REQ-SAFE-001 REQ-E2E-001 REQ-E2E-002 REQ-E2E-003
// (corruption -> not delivered; repeat / skip / lost-frame counting and the E2E-owned
//  reception timeout, independent of the QM COM deadline (002); protect-on-transmit incl.
//  counter advance and 15->0 wrap.)

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

// The lost-frame count: each gap adds delta - 1, and a frame that arrived CORRUPT counts as not
// received intact (its counter cannot be trusted) — AUTOSAR E2E's rule.
fn test_lost_frames_count_every_frame_not_received_intact() {
	mut tx := TxState{}
	mut rx := RxState{}
	mut f := [8]u8{}
	tx.protect(&f[0], 8, id, crc_pos, ctr_pos) // 0
	assert rx.check(&f[0], 8, id, crc_pos, ctr_pos) == .ok
	tx.protect(&f[0], 8, id, crc_pos, ctr_pos) // 1 lost
	tx.protect(&f[0], 8, id, crc_pos, ctr_pos) // 2 lost
	tx.protect(&f[0], 8, id, crc_pos, ctr_pos) // 3 arrives
	assert rx.check(&f[0], 8, id, crc_pos, ctr_pos) == .lost
	assert rx.lost_frames == 2
	tx.protect(&f[0], 8, id, crc_pos, ctr_pos) // 4 arrives corrupt
	f[0] ^= 0xFF
	assert rx.check(&f[0], 8, id, crc_pos, ctr_pos) == .crc_error
	f[0] ^= 0xFF
	tx.protect(&f[0], 8, id, crc_pos, ctr_pos) // 5 good
	assert rx.check(&f[0], 8, id, crc_pos, ctr_pos) == .lost
	assert rx.lost_frames == 3
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

// REQ-E2E-002: total loss of the sender, detected by E2E's OWN timeout — armed at start, refreshed
// only by a VALID message (a repeat or a CRC error is not one), firing once.
fn test_own_timeout_detects_sender_loss() {
	mut tx := TxState{}
	mut rx := RxState{
		timeout_us: 1000
	}
	assert !rx.expired(50_000), 'an unarmed timeout must not fire'
	rx.arm(0)
	assert !rx.expired(1000)
	assert rx.expired(1001), 'sender absent since start'
	assert !rx.expired(5000), 'fires once'
	mut f := [8]u8{}
	tx.protect(&f[0], 8, id, crc_pos, ctr_pos)
	if rx.check(&f[0], 8, id, crc_pos, ctr_pos).usable() {
		rx.on_valid(10_000)
	}
	assert !rx.expired(10_500)
	// a stuck sender: the same frame again is a repeat, which does not refresh the timeout
	if rx.check(&f[0], 8, id, crc_pos, ctr_pos).usable() {
		rx.on_valid(10_900)
	}
	assert rx.expired(11_001), 'a repeat kept the sender alive'
}
