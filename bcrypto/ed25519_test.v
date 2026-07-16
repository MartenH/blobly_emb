module bcrypto

import os

// @verifies REQ-BOOT-011, REQ-BOOT-017
// Ed25519 against the RFC 8032 §7.1 test vectors — public-key derivation,
// signing, and verification all match — plus the negative cases that matter
// for secure boot: a single-bit change in the image, the signature, or the
// public key is rejected.

fn unhex(s string) []u8 {
	mut out := []u8{len: s.len / 2}
	for i in 0 .. out.len {
		out[i] = u8(('0x' + s[i * 2..i * 2 + 2]).u8())
	}
	return out
}

fn fix32(b []u8) [32]u8 {
	mut a := [32]u8{}
	for i in 0 .. 32 {
		a[i] = b[i]
	}
	return a
}

fn fix64(b []u8) [64]u8 {
	mut a := [64]u8{}
	for i in 0 .. 64 {
		a[i] = b[i]
	}
	return a
}

struct Vec {
	seed string
	pub  string
	msg  string
	sig  string
}

const rfc8032 = [
	Vec{'9d61b19deffebc3ea6a37fdec95b34c05de54dd53a5e21b93a41c5daf62b9a1a', 'a97489a9a5d672365c1b2c33f210c84c443e561972992d1f40df50f052a53703', '', 'b6d2fd406d94c64d8bf5b9198ff4920c6152bccfc11854c32b21f1ff017b6c66d08a6fe8a9842160f2592cbd465f239b480f6058c3abf217eaf6288ec3d09507'},
	Vec{'4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb', '3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c', '72', '92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00'},
	Vec{'c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7', 'fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025', 'af82', '6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a'},
]!

fn test_ed25519_rfc8032() {
	for v in rfc8032 {
		seed := fix32(unhex(v.seed))
		exp_pub := fix32(unhex(v.pub))
		msg := unhex(v.msg)
		exp_sig := fix64(unhex(v.sig))
		// public-key derivation
		assert public_key(seed) == exp_pub
		// signing reproduces the exact RFC signature
		assert sign(seed, msg) == exp_sig
		// verification accepts it
		assert verify(exp_pub, msg, exp_sig)
	}
}

fn test_ed25519_rejects_tampering() {
	v := rfc8032[2] // the 2-byte message case
	pkey := fix32(unhex(v.pub))
	msg := unhex(v.msg)
	sig := fix64(unhex(v.sig))
	assert verify(pkey, msg, sig) // baseline

	// a flipped signature byte -> reject
	mut bad_sig := sig
	bad_sig[10] ^= 0x01
	assert !verify(pkey, msg, bad_sig)
	// flip a byte in the S half too
	mut bad_sig2 := sig
	bad_sig2[40] ^= 0x01
	assert !verify(pkey, msg, bad_sig2)

	// a flipped message byte -> reject
	mut bad_msg := msg.clone()
	bad_msg[0] ^= 0x01
	assert !verify(pkey, bad_msg, sig)

	// a flipped public-key byte -> reject
	mut bad_pub := pkey
	bad_pub[0] ^= 0x01
	assert !verify(bad_pub, msg, sig)

	// this signature under a DIFFERENT valid key -> reject
	other := fix32(unhex(rfc8032[1].pub))
	assert !verify(other, msg, sig)
}

// a round trip on a non-RFC seed and a longer message (the image-sized path)
fn test_ed25519_roundtrip_large() {
	mut seed := [32]u8{}
	for i in 0 .. 32 {
		seed[i] = u8((i * 7 + 3) & 0xff)
	}
	pkey := public_key(seed)
	mut msg := []u8{len: 5000}
	for i in 0 .. msg.len {
		msg[i] = u8((i * 131 + 17) & 0xff)
	}
	sig := sign(seed, msg)
	assert verify(pkey, msg, sig)
	msg[4999] ^= 0x01
	assert !verify(pkey, msg, sig)
}

// the streaming Verifier (the boot's flash-chunked path) must match one-shot verify
fn test_ed25519_streaming_verify() {
	mut seed := [32]u8{}
	for i in 0 .. 32 {
		seed[i] = u8((i * 11 + 5) & 0xff)
	}
	pkey := public_key(seed)
	mut msg := []u8{len: 3333}
	for i in 0 .. msg.len {
		msg[i] = u8((i * 97 + 13) & 0xff)
	}
	sig := sign(seed, msg)
	// feed in uneven chunks
	mut v := verify_start(pkey, sig)
	mut off := 0
	for step in [1, 500, 33, 1024, 700] {
		mut n := step
		if off + n > msg.len {
			n = msg.len - off
		}
		if n > 0 {
			v.update(unsafe { &msg[off] }, n)
			off += n
		}
	}
	if off < msg.len {
		v.update(unsafe { &msg[off] }, msg.len - off)
	}
	assert v.finish()
	// tamper mid-stream -> reject
	mut bad := msg.clone()
	bad[1000] ^= 0x01
	mut v2 := verify_start(pkey, sig)
	v2.update(unsafe { &bad[0] }, bad.len)
	assert !v2.finish()
}

// @verifies REQ-BOOT-017
// The on-target verify path must be allocation-free (the boot has no heap). We
// can't inspect the C here, but the source guard forbids the slice/heap forms
// in the verify call graph — a regression to []u8{len:} or .clone() would trip
// the freestanding boot at runtime (caught structurally, like lint_vinit).
fn test_verify_path_no_heap_forms() {
	src := os.read_file(os.join_path(os.dir(@FILE), 'ed25519.v')) or {
		assert false, 'ed25519.v unreadable'
		return
	}
	lines := src.split_into_lines()
	mut in_verify_graph := false
	for ln in lines {
		t := ln.trim_space()
		// the target verify call graph: everything from verify_start through the
		// sign() boundary (sign is host-only and may use dynamic forms)
		if t.starts_with('pub fn verify_start') || t.starts_with('fn reduce_scalar')
			|| t.starts_with('fn modl') || t.starts_with('pub fn (mut v Verifier)') {
			in_verify_graph = true
		}
		if t.starts_with('pub fn public_key') || t.starts_with('pub fn sign') {
			in_verify_graph = false // host-only from here
		}
		if in_verify_graph {
			assert !ln.contains('[]u8{len'), 'heap slice in the verify path: ${t}'
			assert !ln.contains('[]i64{len'), 'heap slice in the verify path: ${t}'
			assert !ln.contains('.clone()'), 'clone in the verify path: ${t}'
		}
	}
}
