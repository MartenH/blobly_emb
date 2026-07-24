module secoc

// @verifies SYS-REQ-SEC-001 REQ-SEC-001
// (verify-reject on tamper and wrong key — the authentication clause.)
// NOT tagged, two GAPS the sweep surfaced (both in requirements/sec.toml):
//  - REQ-SEC-002 (replay): live-state rejection is tested, but freshness restarts at
//    zero across reset, so a captured frame replays after a reboot.
//  - REQ-SEC-003 (protect-on-tx / freshness advances): freshness is a u8, so the 257th
//    unchanged-payload frame repeats freshness 0 and the FIRST frame's CMAC — and at
//    the 255->0 wrap a receiver accepts a captured first frame as the next value. The
//    'consecutive frames are never byte-identical / monotone freshness' property the
//    requirement needs wants a wider counter or resync. Both are the same design
//    decision as SEC-002 (freshness scheme + NvM/resync).

fn eq16(a [16]u8, b [16]u8) bool {
	for i in 0 .. 16 {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// FIPS-197 Appendix B / C.1 AES-128 known-answer vector.
fn test_aes128_fips197() {
	key := [u8(0x00), 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c,
		0x0d, 0x0e, 0x0f]!
	mut blk := [u8(0x00), 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb,
		0xcc, 0xdd, 0xee, 0xff]!
	k := new_key(key)
	encrypt_block(k.rk, mut blk)
	expect := [u8(0x69), 0xc4, 0xe0, 0xd8, 0x6a, 0x7b, 0x04, 0x30, 0xd8, 0xcd, 0xb7, 0x80, 0x70,
		0xb4, 0xc5, 0x5a]!
	assert eq16(blk, expect)
}

// RFC 4493 AES-CMAC test vectors (key 2b7e1516...).
fn test_cmac_rfc4493() {
	key := [u8(0x2b), 0x7e, 0x15, 0x16, 0x28, 0xae, 0xd2, 0xa6, 0xab, 0xf7, 0x15, 0x88, 0x09,
		0xcf, 0x4f, 0x3c]!
	k := new_key(key)
	msg := [u8(0x6b), 0xc1, 0xbe, 0xe2, 0x2e, 0x40, 0x9f, 0x96, 0xe9, 0x3d, 0x7e, 0x11, 0x73,
		0x93, 0x17, 0x2a, 0xae, 0x2d, 0x8a, 0x57, 0x1e, 0x03, 0xac, 0x9c, 0x9e, 0xb7, 0x6f,
		0xac, 0x45, 0xaf, 0x8e, 0x51, 0x30, 0xc8, 0x1c, 0x46, 0xa3, 0x5c, 0xe4, 0x11, 0xe5,
		0xfb, 0xc1, 0x19, 0x1a, 0x0a, 0x52, 0xef, 0xf6, 0x9f, 0x24, 0x45, 0xdf, 0x4f, 0x9b,
		0x17, 0xad, 0x2b, 0x41, 0x7b, 0xe6, 0x6c, 0x37, 0x10]!

	mut mac := [16]u8{}
	cmac(k.rk, &msg[0], 0, mut mac)
	assert eq16(mac, [u8(0xbb), 0x1d, 0x69, 0x29, 0xe9, 0x59, 0x37, 0x28, 0x7f, 0xa3, 0x7d, 0x12,
		0x9b, 0x75, 0x67, 0x46]!)

	cmac(k.rk, &msg[0], 16, mut mac)
	assert eq16(mac, [u8(0x07), 0x0a, 0x16, 0xb4, 0x6b, 0x4d, 0x41, 0x44, 0xf7, 0x9b, 0xdd, 0x9d,
		0xd0, 0x4a, 0x28, 0x7c]!)

	cmac(k.rk, &msg[0], 40, mut mac)
	assert eq16(mac, [u8(0xdf), 0xa6, 0x67, 0x47, 0xde, 0x9a, 0xe6, 0x30, 0x30, 0xca, 0x32, 0x61,
		0x14, 0x97, 0xc8, 0x27]!)

	cmac(k.rk, &msg[0], 64, mut mac)
	assert eq16(mac, [u8(0x51), 0xf0, 0xbe, 0xbf, 0x7e, 0x3b, 0x9d, 0x92, 0xfc, 0x49, 0x74, 0x17,
		0x79, 0x36, 0x3c, 0xfe]!)
}

const fresh_pos = 1
const mac_pos = 2
const mac_len = 4
const data_id = u16(0x1234)

fn demo_key() Key {
	return new_key([u8(0x10), 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b,
		0x1c, 0x1d, 0x1e, 0x1f]!)
}

fn test_protect_then_verify() {
	key := demo_key()
	mut tx := TxState{}
	mut rx := RxState{}
	mut f := [8]u8{}
	f[0] = 0x42
	tx.protect(&key, &f[0], 8, data_id, fresh_pos, mac_pos, mac_len)
	assert rx.verify(&key, &f[0], 8, data_id, fresh_pos, mac_pos, mac_len) == .ok
}

fn test_tamper_is_auth_failed() {
	key := demo_key()
	mut tx := TxState{}
	mut rx := RxState{}
	mut f := [8]u8{}
	f[0] = 0x42
	tx.protect(&key, &f[0], 8, data_id, fresh_pos, mac_pos, mac_len)
	f[0] ^= 0xFF // tamper the payload — MAC no longer matches
	assert rx.verify(&key, &f[0], 8, data_id, fresh_pos, mac_pos, mac_len) == .auth_failed
}

fn test_wrong_key_is_auth_failed() {
	key := demo_key()
	mut tx := TxState{}
	mut f := [8]u8{}
	tx.protect(&key, &f[0], 8, data_id, fresh_pos, mac_pos, mac_len)
	other := new_key([u8(0xaa), 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9]!)
	mut rx := RxState{}
	assert rx.verify(&other, &f[0], 8, data_id, fresh_pos, mac_pos, mac_len) == .auth_failed
}

fn test_replay_detected() {
	key := demo_key()
	mut tx := TxState{}
	mut rx := RxState{}
	mut f := [8]u8{}
	tx.protect(&key, &f[0], 8, data_id, fresh_pos, mac_pos, mac_len) // freshness 0
	assert rx.verify(&key, &f[0], 8, data_id, fresh_pos, mac_pos, mac_len) == .ok
	// replay the SAME (valid) frame — freshness didn't advance
	assert rx.verify(&key, &f[0], 8, data_id, fresh_pos, mac_pos, mac_len) == .replay
	// a fresh frame is accepted again
	mut f2 := [8]u8{}
	tx.protect(&key, &f2[0], 8, data_id, fresh_pos, mac_pos, mac_len) // freshness 1
	assert rx.verify(&key, &f2[0], 8, data_id, fresh_pos, mac_pos, mac_len) == .ok
}
