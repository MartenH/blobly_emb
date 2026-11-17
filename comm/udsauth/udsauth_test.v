module udsauth

import bcrypto
import comm.uds

// @verifies REQ-DIAG-121 REQ-DIAG-122 REQ-DIAG-126 REQ-DIAG-127
// (the keys per level and the real Ed25519 verify behind uds.AuthOps, stepped: the reference key is
//  the dev tester seed's public half; the GOLDEN signature of the challenge 00..1F under the dev
//  seed — committed byte for byte here, in comm/uds/auth_test.v and in blobly_net — verifies at its
//  level and fails under another level's key, with a tampered challenge or signature, a non-canonical
//  S, a level with no key and a level outside 1..8; whole 0x29 exchanges through a server — the
//  golden 06 answered 0x78 and then ISO's 21-byte answer, every challenge fresh and a proof of an
//  earlier one refused.)

const gv_seed = [u8(0x20), 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x2b, 0x2c,
	0x2d, 0x2e, 0x2f, 0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x3b, 0x3c,
	0x3d, 0x3e, 0x3f]!

const gv_sig = [u8(0xea), 0x92, 0xd2, 0x4e, 0xda, 0x4c, 0x09, 0x9e, 0xa3, 0xc1, 0xaa, 0xa1, 0x0c,
	0x86, 0xcd, 0x63, 0xe2, 0xa0, 0x43, 0x0a, 0xaf, 0x86, 0x5d, 0xb6, 0xed, 0x60, 0xf8, 0x12, 0x9d,
	0xe7, 0xa3, 0x63, 0xa6, 0x1c, 0xdc, 0x52, 0x51, 0xb5, 0xc7, 0x4f, 0x07, 0x75, 0x56, 0x39, 0xb3,
	0x3d, 0xda, 0xd8, 0x69, 0x9e, 0xf8, 0x5b, 0xe6, 0x1c, 0xbe, 0x8d, 0x60, 0x3e, 0x8e, 0x80, 0xaa,
	0x7c, 0x1b, 0x09]!

fn challenge() [32]u8 {
	mut c := [32]u8{}
	for i in 0 .. 32 {
		c[i] = u8(i)
	}
	return c
}

fn sig_copy() [64]u8 {
	mut s := [64]u8{}
	for i in 0 .. 64 {
		s[i] = gv_sig[i]
	}
	return s
}

// verify_with runs the seam as a server does: start, then a step per pass until the verdict
fn verify_with(mut k Keys, level u8, c [32]u8, sig [64]u8) bool {
	ops := k.ops()
	ops.start(ops.ctx, level, &c[0], 32, &sig[0])
	mut passes := 0
	for {
		v := ops.step(ops.ctx)
		passes++
		if v != .verifying {
			if v == .valid {
				// a whole verify, a slice per pass: about 10,300 / verify_step_mults
				assert passes >= 65 && passes <= 80, '${passes} passes'
			}
			return v == .valid
		}
		assert passes < 1000
	}
	return false
}

fn test_the_reference_key_is_the_dev_seed_s_public_half() {
	assert bcrypto.public_key(gv_seed) == reference_key
	// the golden signature is bcrypto's own deterministic signature (RFC 8032)
	c := challenge()
	assert bcrypto.sign(gv_seed, c[..]) == gv_sig
}

fn test_the_golden_vector_verifies_at_its_level_only() {
	mut k := Keys{}
	k.set(1, &reference_key[0])
	other := bcrypto.public_key([32]u8{init: 0x55})
	k.set(2, &other[0])
	c := challenge()
	assert verify_with(mut k, 1, c, gv_sig)
	assert !verify_with(mut k, 2, c, gv_sig), "verified under another level's key"
	assert !verify_with(mut k, 3, c, gv_sig), 'verified at a level with no key'
	assert !verify_with(mut k, 0, c, gv_sig) && !verify_with(mut k, 9, c, gv_sig)
	mut tc := challenge()
	tc[31] ^= 1
	assert !verify_with(mut k, 1, tc, gv_sig), 'a tampered challenge verified'
	mut ts := sig_copy()
	ts[0] ^= 1
	assert !verify_with(mut k, 1, c, ts), 'a tampered signature verified'
	// S + L (non-canonical, the same point): refused (RFC 8032 §8.4)
	l := [u8(0xed), 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58, 0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9,
		0xde, 0x14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10]
	mut nc := sig_copy()
	mut carry := 0
	for i in 0 .. 32 {
		v := int(nc[32 + i]) + int(l[i]) + carry
		nc[32 + i] = u8(v)
		carry = v >> 8
	}
	assert !verify_with(mut k, 1, c, nc), 'a non-canonical S verified'
}

fn test_is_point() {
	assert bcrypto.is_point(reference_key)
	mut bad := [32]u8{}
	bad[0] = 2 // y = 2 is not on the curve
	assert !bcrypto.is_point(bad)
}

fn counting(_ voidptr, out &u8, n int) bool {
	for i in 0 .. n {
		unsafe {
			out[i] = u8(i)
		}
	}
	return true
}

// LcgSeed: a challenge source drawing a different challenge every time (an LCG)
struct LcgSeed {
mut:
	x u32 = 1
}

fn lcg(ctx voidptr, out &u8, n int) bool {
	mut g := unsafe { &LcgSeed(ctx) }
	for i in 0 .. n {
		g.x = g.x * 1103515245 + 12345
		unsafe {
			out[i] = u8(g.x >> 16)
		}
	}
	return true
}

fn auth_server(mut k Keys, seed uds.SecurityOps) uds.Server {
	mut s := uds.Server{}
	s.init(256)
	s.security = seed
	s.auth = k.ops()
	s.security_levels = 0x01
	mut resp := [256]u8{}
	ext := [u8(0x10), 0x03]
	s.handle(&ext[0], 2, &resp[0])
	return s
}

fn req05() []u8 {
	mut r05 := [u8(0x29), 0x05, 0x01]
	r05 << uds.ed25519_algorithm[..]
	return r05
}

fn req06(sig []u8) []u8 {
	mut r06 := [u8(0x29), 0x06]
	r06 << uds.ed25519_algorithm[..]
	r06 << [u8(0x00), 0x40]
	r06 << sig
	r06 << [u8(0), 0, 0, 0]
	return r06
}

// prove: send the 06 for `sig` — answered 0x78 at once — and drive the owed answer a pass at a time
// (pending_step, as an owner's pump does) until the final answer, returned
fn prove(mut s uds.Server, sig []u8) []u8 {
	mut resp := [256]u8{}
	r06 := req06(sig)
	assert r06.len == uds.auth_proof_req_len
	n := s.handle(unsafe { &r06[0] }, r06.len, &resp[0])
	assert resp[..n] == [u8(0x7F), 0x29, 0x78], 'the 06 was not answered responsePending'
	for _ in 0 .. 1000 {
		m := s.pending_step(&resp[0], 256)
		if m > 0 {
			assert s.pending() == (m == 3 && resp[2] == 0x78)
			if !s.pending() {
				return resp[..m].clone()
			}
		}
	}
	assert false, 'the owed answer never came'
	return []u8{}
}

// ask: a 05, its 32-byte challenge
fn ask(mut s uds.Server) []u8 {
	mut resp := [256]u8{}
	r05 := req05()
	n := s.handle(unsafe { &r05[0] }, r05.len, &resp[0])
	assert n == uds.auth_challenge_answer_len
	return resp[uds.auth_answer_challenge_at..uds.auth_answer_challenge_at + 32].clone()
}

// a whole exchange through a server: the golden 06 request, answered 0x78 then ISO 14229-1:2020's
// 21-byte answer (ownershipVerified, the algorithm, no session key), unlocks level 1
fn test_a_server_unlocks_with_the_golden_proof() {
	mut k := &Keys{}
	k.set(1, &reference_key[0])
	mut s := auth_server(mut k, uds.SecurityOps{
		seed: counting
	})
	c := ask(mut s)
	assert c == challenge()[..]
	mut want := [u8(0x69), 0x06, 0x12]
	want << uds.ed25519_algorithm[..]
	want << [u8(0x00), 0x00]
	assert want.len == uds.auth_proof_answer_len
	assert prove(mut s, gv_sig[..]) == want
	assert s.unlocked == 1
}

// REQ-DIAG-121 / 122: every 05 draws a fresh challenge, and a proof captured from an earlier exchange
// fails against the next one — sniffing a valid 06 buys no unlock
fn test_every_challenge_is_fresh_and_an_old_proof_is_refused() {
	mut k := &Keys{}
	k.set(1, &reference_key[0])
	mut g := &LcgSeed{}
	mut s := auth_server(mut k, uds.SecurityOps{
		ctx:  unsafe { voidptr(g) }
		seed: lcg
	})
	c1 := ask(mut s)
	sig1 := bcrypto.sign(gv_seed, c1)
	assert prove(mut s, sig1[..])[0] == 0x69
	assert s.unlocked == 1
	c2 := ask(mut s)
	assert c2 != c1, 'a challenge was handed out twice'
	assert prove(mut s, sig1[..]) == [u8(0x7F), 0x29, 0x58], 'a replayed proof verified'
	// and the fresh one's own proof still works after a refused one
	c3 := ask(mut s)
	assert c3 != c2 && c3 != c1
	sig3 := bcrypto.sign(gv_seed, c3)
	assert prove(mut s, sig3[..])[0] == 0x69
}
