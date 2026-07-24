module e2e

// @verifies REQ-E2E-004
// E2E + SecOC on ONE frame, exactly as the requirement defines the composition:
// disjoint byte ranges (E2E covers only the application payload — never the SecOC
// freshness/MAC bytes stamped after it), TX order E2E-then-SecOC, RX order
// SecOC-then-E2E, and neither protection masking a fault the other detects.
//
// This test exists because the naive composition was BROKEN and nothing caught it:
// e2e.compute() covered every byte except its own CRC, so SecOC's post-stamp of
// freshness+MAC invalidated the CRC and the receiver failed every authentic frame
// (found by this requirement's coverage sweep, 2026-07-24). protect_ex/check_ex
// carry the exclusion windows that make the requirement's layout actually verify.

import comm.secoc

// the layout from the requirement's example: payload 0-2, E2E crc@3 ctr@4,
// SecOC fresh@5 mac@6-7 — every protection field disjoint
const did = u16(0x123)
const crc_pos = 3
const ctr_pos = 4
const fresh_pos = 5
const mac_pos = 6
const mac_len = 2

fn tx_frame(mut etx TxState, mut stx secoc.TxState, key &secoc.Key, seed u8) [8]u8 {
	mut d := [8]u8{}
	d[0] = seed
	d[1] = 0x22
	d[2] = 0x33
	// TX order per the requirement: E2E over the payload first (excluding SecOC's
	// bytes), then SecOC authenticates the E2E-protected result
	etx.protect_ex(&d[0], 8, did, crc_pos, ctr_pos, fresh_pos, 1, mac_pos, mac_len)
	stx.protect(key, &d[0], 8, did, fresh_pos, mac_pos, mac_len)
	return d
}

fn test_composed_roundtrip_verifies() {
	key := secoc.new_key([16]u8{init: u8(7)})
	mut etx := TxState{}
	mut stx := secoc.TxState{}
	mut erx := RxState{}
	mut srx := secoc.RxState{}
	for seed in u8(1) .. u8(6) {
		d := tx_frame(mut etx, mut stx, &key, seed)
		// RX order per the requirement: only an authentic message reaches the E2E check
		assert srx.verify(&key, &d[0], 8, did, fresh_pos, mac_pos, mac_len) == .ok
		assert erx.check_ex(&d[0], 8, did, crc_pos, ctr_pos, fresh_pos, 1, mac_pos, mac_len) == .ok
	}
}

fn test_disjoint_ranges_secoc_stamp_does_not_invalidate_e2e() {
	key := secoc.new_key([16]u8{init: u8(7)})
	mut etx := TxState{}
	mut stx := secoc.TxState{}
	mut d := tx_frame(mut etx, mut stx, &key, 9)
	// mutate the SecOC fields AFTER the fact: the E2E check must be INDIFFERENT —
	// that is the disjointness the requirement demands (SecOC catches it instead)
	d[fresh_pos] = d[fresh_pos] + 1
	d[mac_pos] = d[mac_pos] ^ 0xFF
	mut erx := RxState{}
	assert erx.check_ex(&d[0], 8, did, crc_pos, ctr_pos, fresh_pos, 1, mac_pos, mac_len) == .ok
	mut srx := secoc.RxState{}
	assert srx.verify(&key, &d[0], 8, did, fresh_pos, mac_pos, mac_len) == .auth_failed
}

fn test_neither_masks_the_other() {
	key := secoc.new_key([16]u8{init: u8(7)})
	mut etx := TxState{}
	mut stx := secoc.TxState{}
	mut erx := RxState{}
	mut srx := secoc.RxState{}
	// prime both receivers with one good frame
	d0 := tx_frame(mut etx, mut stx, &key, 1)
	assert srx.verify(&key, &d0[0], 8, did, fresh_pos, mac_pos, mac_len) == .ok
	assert erx.check_ex(&d0[0], 8, did, crc_pos, ctr_pos, fresh_pos, 1, mac_pos, mac_len) == .ok

	// an E2E-detectable fault SecOC cannot see: a stuck sender counter on an
	// otherwise freshly-authenticated frame — SecOC passes, E2E reports repeated
	etx.counter = (etx.counter - 1) & 0x0F // rewind: same counter as the last frame
	d1 := tx_frame(mut etx, mut stx, &key, 1)
	assert srx.verify(&key, &d1[0], 8, did, fresh_pos, mac_pos, mac_len) == .ok
	assert erx.check_ex(&d1[0], 8, did, crc_pos, ctr_pos, fresh_pos, 1, mac_pos, mac_len) == .repeated

	// a payload corruption: SecOC (verified FIRST per the order) already refuses it —
	// the fault never reaches the application through either gate
	mut d2 := tx_frame(mut etx, mut stx, &key, 2)
	d2[0] = d2[0] ^ 0x55
	assert srx.verify(&key, &d2[0], 8, did, fresh_pos, mac_pos, mac_len) == .auth_failed
}
