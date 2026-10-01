module e2e

// @verifies SYS-REQ-SAFE-001 REQ-E2E-001 REQ-E2E-002 REQ-E2E-003
// (corruption -> not delivered; repeat / skip / lost-frame counting and the E2E-owned
//  reception timeout, independent of the QM COM deadline (002); protect-on-transmit incl.
//  counter advance and the Profile 1 14->0 wrap; the CRC pinned to AUTOSAR E2E Profile 1.)

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

fn test_counter_wraps_14_to_0() {
	mut tx := TxState{}
	mut rx := RxState{}
	mut f := [8]u8{}
	for n in 0 .. 32 { // past two Profile 1 wraps: 14 -> 0 is the next counter, not a skip
		tx.protect(&f[0], 8, id, crc_pos, ctr_pos)
		assert f[ctr_pos] & 0x0F == u8(n % 15)
		assert rx.check(&f[0], 8, id, crc_pos, ctr_pos) == .ok
	}
}

// AUTOSAR E2E Profile 1 (Data ID mode BOTH), pinned by vectors from an INDEPENDENT
// implementation — autosar-e2e 1.0.0; blobly_net's sut/e2e_oracle.py regenerates them, and
// blobly_net's autosar_p01 is pinned by the same table — on overspeed's BrakeStatus layout:
// payload E8 03 5A 00, CRC byte 4, counter in byte 5's low nibble, Data ID 0x1244.
const p01_both = [u8(0xE8), 0xF5, 0xD2, 0xCF, 0x9C, 0x81, 0xA6, 0xBB, 0x00, 0x1D, 0x3A, 0x27,
	0x74, 0x69, 0x4E]

fn test_crc_is_autosar_profile_1() {
	mut tx := TxState{}
	for n in 0 .. 15 {
		mut f := [6]u8{}
		f[0] = 0xE8
		f[1] = 0x03
		f[2] = 0x5A
		tx.protect(&f[0], 6, u16(0x1244), 4, 5)
		assert f[5] & 0x0F == u8(n)
		assert f[4] == p01_both[n], 'counter ${n}: 0x${f[4]:02X}, the reference says 0x${p01_both[n]:02X}'
	}
}

// 15 is not a Profile 1 counter: a frame carrying it is refused, whatever its CRC says
fn test_counter_fifteen_is_refused() {
	mut rx := RxState{}
	mut f := [6]u8{}
	f[0] = 0xE8
	f[1] = 0x03
	f[2] = 0x5A
	f[5] = 0x0F
	f[4] = compute(&f[0], 6, u16(0x1244), 4, 0, 0, 0, 0)
	assert rx.check(&f[0], 6, u16(0x1244), 4, 5) == .crc_error
	assert !rx.started, 'an invalid counter must not become the sequence reference'
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

// the receive side counts modulo 15 across the wrap: a loss or a repeat straddling 14 -> 0 is
// the same loss or repeat as anywhere else
fn test_loss_and_repeat_across_the_wrap() {
	mut f := [8]u8{}
	for last, recv in {
		u8(13): u8(0)
		14:     1
	} {
		mut tx := TxState{
			counter: last
		}
		mut rx := RxState{}
		tx.protect(&f[0], 8, id, crc_pos, ctr_pos)
		assert rx.check(&f[0], 8, id, crc_pos, ctr_pos) == .ok
		tx.counter = recv
		tx.protect(&f[0], 8, id, crc_pos, ctr_pos)
		assert rx.check(&f[0], 8, id, crc_pos, ctr_pos) == .lost, '${last} -> ${recv}'
		assert rx.lost_frames == 1, '${last} -> ${recv}: ${rx.lost_frames} lost'
	}
	mut tx := TxState{
		counter: 14
	}
	mut rx := RxState{}
	tx.protect(&f[0], 8, id, crc_pos, ctr_pos)
	assert rx.check(&f[0], 8, id, crc_pos, ctr_pos) == .ok
	tx.counter = 14
	tx.protect(&f[0], 8, id, crc_pos, ctr_pos)
	assert rx.check(&f[0], 8, id, crc_pos, ctr_pos) == .repeated
	tx.counter = 15 // a counter that is not Profile 1's is never stamped
	tx.protect(&f[0], 8, id, crc_pos, ctr_pos)
	assert f[ctr_pos] & 0x0F == 0
}

// receive: the receiver's rule for one checked frame (REQ-E2E-002)
fn test_receive_publishes_each_verdict_by_the_rule() {
	mut r := RxState{
		timeout_us: 1000
	}
	r.arm(0)
	assert r.receive(100, .ok) == .ok
	assert r.receive(200, .lost) == .ok, 'a lost frame is usable: its value counts'
	assert r.receive(300, .repeated) == .none, 'a repeat publishes nothing'
	// a usable frame after the timeout ran out unseen is published as the timeout
	assert r.receive(1500, .ok) == .timeout
	assert r.receive(1600, .ok) == .ok, 'and the next one is fresh again'
	// a corrupt frame is an integrity failure, and does NOT re-arm a live timeout
	assert r.receive(1700, .crc_error) == .integrity
	assert r.expired(2601), 'corrupt frames kept the sender alive'
	// once the timeout has fired, a corrupt frame restarts it (a fresh window for the next)
	assert r.receive(2700, .crc_error) == .integrity
	assert !r.expired(3600) && r.expired(3701)
	// ...and so does one arriving after the deadline passed but BEFORE anyone polled it: the
	// corrupt frame is the newer fact, and no stale timeout is left to overwrite it
	mut q := RxState{
		timeout_us: 1000
	}
	q.arm(0)
	assert q.receive(1500, .crc_error) == .integrity
	assert !q.expired(1600), 'the elapsed deadline was left to fire after the integrity verdict'
}

// receive_ex: a latched commanded pause (0x28) suspends the late judgement — its deadline is the
// stale pre-silence one
fn test_a_suspended_deadline_judges_nothing_late() {
	mut r := RxState{
		timeout_us: 1000
	}
	r.arm(0)
	assert r.receive_ex(5000, .ok, true) == .ok, 'judged late against a suspended deadline'
	assert !r.expired(5500), 'the valid frame re-armed it'
	// and a corrupt frame under suspension leaves a live deadline alone
	mut q := RxState{
		timeout_us: 1000
	}
	q.arm(0)
	assert q.receive_ex(5000, .crc_error, true) == .integrity
	assert q.expired(5001), 'a suspended corrupt frame re-armed a deadline that never fired'
}
