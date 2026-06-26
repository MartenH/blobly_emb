module secoc

// SecOC (Secure Onboard Communication): authenticate a frame with a truncated
// AES-128 **CMAC** over (data_id ‖ payload ‖ freshness), plus a monotonic
// **freshness** counter for replay protection. Symmetric-key (build-time config),
// no-alloc.
//
// vs E2E: E2E is an *unkeyed* CRC — it catches RANDOM faults (corruption, loss).
// SecOC's MAC is *keyed*: only a holder of the key can forge it, so it detects a
// malicious sender, tampering, and replay (security / ISO-SAE 21434) rather than
// nature (safety / ISO 26262). Same wrap-on-tx / check-on-rx shape; different math.
//
// AES-128 (encrypt only) + CMAC (RFC 4493) are below, validated in the tests
// against the FIPS-197 and RFC 4493 vectors.

const sbox = [u8(0x63), 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe,
	0xd7, 0xab, 0x76, 0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf,
	0x9c, 0xa4, 0x72, 0xc0, 0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5,
	0xf1, 0x71, 0xd8, 0x31, 0x15, 0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12,
	0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75, 0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52,
	0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84, 0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b,
	0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf, 0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33,
	0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8, 0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d,
	0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2, 0xcd, 0x0c, 0x13, 0xec, 0x5f,
	0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73, 0x60, 0x81, 0x4f, 0xdc,
	0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb, 0xe0, 0x32, 0x3a,
	0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79, 0xe7, 0xc8,
	0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08, 0xba,
	0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
	0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d,
	0x9e, 0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55,
	0x28, 0xdf, 0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0,
	0x54, 0xbb, 0x16]!

const rcon = [u8(0x01), 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36]!

// Key holds the AES-128 expanded round keys (176 bytes = 11 × 16).
pub struct Key {
pub mut:
	rk [176]u8
}

// new_key expands a 16-byte AES-128 key.
pub fn new_key(k [16]u8) Key {
	mut key := Key{}
	for i in 0 .. 16 {
		key.rk[i] = k[i]
	}
	mut i := 16
	for i < 176 { // one 4-byte word per iteration
		mut t0 := key.rk[i - 4]
		mut t1 := key.rk[i - 3]
		mut t2 := key.rk[i - 2]
		mut t3 := key.rk[i - 1]
		if i % 16 == 0 {
			// RotWord + SubWord + Rcon
			tmp := t0
			t0 = sbox[t1] ^ rcon[i / 16 - 1]
			t1 = sbox[t2]
			t2 = sbox[t3]
			t3 = sbox[tmp]
		}
		key.rk[i] = key.rk[i - 16] ^ t0
		key.rk[i + 1] = key.rk[i - 15] ^ t1
		key.rk[i + 2] = key.rk[i - 14] ^ t2
		key.rk[i + 3] = key.rk[i - 13] ^ t3
		i += 4
	}
	return key
}

fn xtime(x u8) u8 {
	return if x & 0x80 != 0 { (x << 1) ^ 0x1b } else { x << 1 }
}

// encrypt_block encrypts one 16-byte block in place (AES-128, column-major state).
fn encrypt_block(rk [176]u8, mut s [16]u8) {
	for i in 0 .. 16 {
		s[i] ^= rk[i]
	}
	for round in 1 .. 11 {
		// SubBytes
		for i in 0 .. 16 {
			s[i] = sbox[s[i]]
		}
		// ShiftRows (rows 1,2,3 rotate left by 1,2,3 across the 4 columns)
		mut t := s[1]
		s[1] = s[5]
		s[5] = s[9]
		s[9] = s[13]
		s[13] = t
		t = s[2]
		s[2] = s[10]
		s[10] = t
		t = s[6]
		s[6] = s[14]
		s[14] = t
		t = s[15]
		s[15] = s[11]
		s[11] = s[7]
		s[7] = s[3]
		s[3] = t
		// MixColumns (skip in the final round)
		if round != 10 {
			for c in 0 .. 4 {
				b := c * 4
				a0 := s[b]
				a1 := s[b + 1]
				a2 := s[b + 2]
				a3 := s[b + 3]
				s[b] = xtime(a0) ^ (xtime(a1) ^ a1) ^ a2 ^ a3
				s[b + 1] = a0 ^ xtime(a1) ^ (xtime(a2) ^ a2) ^ a3
				s[b + 2] = a0 ^ a1 ^ xtime(a2) ^ (xtime(a3) ^ a3)
				s[b + 3] = (xtime(a0) ^ a0) ^ a1 ^ a2 ^ xtime(a3)
			}
		}
		// AddRoundKey
		for i in 0 .. 16 {
			s[i] ^= rk[round * 16 + i]
		}
	}
}

// gf_double left-shifts a 128-bit block by 1 in GF(2^128) (the CMAC subkey op).
fn gf_double(b [16]u8) [16]u8 {
	mut out := [16]u8{}
	mut carry := u8(0)
	for i := 15; i >= 0; i-- {
		out[i] = (b[i] << 1) | carry
		carry = (b[i] >> 7) & 1
	}
	if b[0] & 0x80 != 0 {
		out[15] ^= 0x87
	}
	return out
}

// cmac computes the AES-CMAC (RFC 4493) of msg[0..len] into out (16 bytes).
fn cmac(rk [176]u8, msg &u8, len int, mut out [16]u8) {
	mut l := [16]u8{}
	encrypt_block(rk, mut l)
	k1 := gf_double(l)
	k2 := gf_double(k1)

	complete := len > 0 && len % 16 == 0
	mut nblocks := (len + 15) / 16
	if nblocks == 0 {
		nblocks = 1
	}
	mut x := [16]u8{}
	for i in 0 .. nblocks - 1 {
		for j in 0 .. 16 {
			x[j] ^= unsafe { msg[i * 16 + j] }
		}
		encrypt_block(rk, mut x)
	}
	base := (nblocks - 1) * 16
	rem := len - base
	mut last := [16]u8{}
	if complete {
		for j in 0 .. 16 {
			last[j] = unsafe { msg[base + j] } ^ k1[j]
		}
	} else {
		for j in 0 .. 16 {
			b := if j < rem {
				unsafe { msg[base + j] }
			} else if j == rem {
				u8(0x80)
			} else {
				u8(0)
			}
			last[j] = b ^ k2[j]
		}
	}
	for j in 0 .. 16 {
		x[j] ^= last[j]
	}
	encrypt_block(rk, mut x)
	for j in 0 .. 16 {
		out[j] = x[j]
	}
}

// mac_input builds the authenticated bytes — data_id (BE) then every frame byte
// except the MAC field — and CMACs them into `out`.
fn mac_input(key &Key, data &u8, dlc int, data_id u16, mac_pos int, mac_len int, mut out [16]u8) {
	mut buf := [66]u8{}
	buf[0] = u8(data_id >> 8)
	buf[1] = u8(data_id)
	mut n := 2
	for i in 0 .. dlc {
		if i < mac_pos || i >= mac_pos + mac_len {
			buf[n] = unsafe { data[i] }
			n++
		}
	}
	cmac(key.rk, &buf[0], n, mut out)
}

pub struct TxState {
pub mut:
	freshness u8
}

// protect stamps the freshness (fresh_pos) and a truncated CMAC (mac_pos, mac_len)
// into `data`, then advances the freshness counter.
pub fn (mut t TxState) protect(key &Key, data &u8, dlc int, data_id u16, fresh_pos int, mac_pos int, mac_len int) {
	n := if mac_len > 16 { 16 } else { mac_len } // CMAC output is 16 bytes
	unsafe {
		data[fresh_pos] = t.freshness
	}
	mut mac := [16]u8{}
	mac_input(key, data, dlc, data_id, mac_pos, n, mut mac)
	for i in 0 .. n {
		unsafe {
			data[mac_pos + i] = mac[i]
		}
	}
	t.freshness++
}

pub enum Status {
	ok
	auth_failed // MAC mismatch — forged or corrupted
	replay      // freshness did not advance — replayed / old frame
}

// usable reports whether the data should be consumed (only an authentic, fresh frame).
pub fn (s Status) usable() bool {
	return s == .ok
}

pub struct RxState {
pub mut:
	last    u8
	started bool
}

// verify recomputes the MAC (constant-time compare) and checks the freshness
// advanced (anti-replay, with a forward window over the 8-bit counter).
pub fn (mut r RxState) verify(key &Key, data &u8, dlc int, data_id u16, fresh_pos int, mac_pos int, mac_len int) Status {
	n := if mac_len > 16 { 16 } else { mac_len } // CMAC output is 16 bytes
	mut mac := [16]u8{}
	mac_input(key, data, dlc, data_id, mac_pos, n, mut mac)
	mut diff := u8(0)
	for i in 0 .. n {
		diff |= unsafe { data[mac_pos + i] } ^ mac[i]
	}
	if diff != 0 {
		return .auth_failed
	}
	fresh := unsafe { data[fresh_pos] }
	if r.started {
		delta := (fresh - r.last) & 0xFF
		if delta == 0 || delta > 128 {
			return .replay
		}
	}
	r.last = fresh
	r.started = true
	return .ok
}
