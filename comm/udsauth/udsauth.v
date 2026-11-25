module udsauth

import bcrypto
import comm.uds

// The keys an application's 0x29 Authentication verifies a proof with (comm/uds auth.v): per
// security level, the tester's Ed25519 PUBLIC key, 32 bytes — `[uds] auth_keys` in ecu.toml. comm/uds
// holds no key and no algorithm; this module joins them through uds.AuthOps and bcrypto's
// streaming verify, the bootloader's verifier (boot/prog.v) — no second implementation.
//
// No heap and no field defaults (the _vinit rule): the generated glue owns one Keys in bss or in its
// state struct and fills it with set() in its init path, before the first request.

// reference_key: blobly_net's published DEV tester public key — the half of examples/keys/tester.seed
// the bootloader's [boot] session_key already trusts. `auth_keys = { "1" = "reference" }` names it.
// Not a secret: over a network it authenticates nobody (REQ-NET-012's bench key rule).
pub const reference_key = [u8(0x29), 0xac, 0xba, 0xe1, 0x41, 0xbc, 0xca, 0xf0, 0xb2, 0x2e, 0x1a,
	0x94, 0xd3, 0x4d, 0x0b, 0xc7, 0x36, 0x1e, 0x52, 0x6d, 0x0b, 0xfe, 0x12, 0xc8, 0x97, 0x94, 0xbc,
	0x93, 0x22, 0x96, 0x6d, 0xd7]!

// verify_step_mults: the field multiplications one comm pass spends on a proof (bcrypto.VerifyJob:
// a whole verify is about 10,300, so about 75 passes). An estimate, not a measurement: the TweetNaCl
// field multiplication is some 4,500 instructions on a Cortex-M7 at -Os, so a slice is of the order
// of a millisecond or two at 400 MHz.
pub const verify_step_mults = 144

// Keys: per level 1..max_security_level, its public key (an all-zero key verifies nothing), and the
// one proof being verified (a server verifies one at a time: its answer is owed meanwhile).
pub struct Keys {
pub mut:
	keys [uds.max_security_level][32]u8
mut:
	job    bcrypto.VerifyJob
	failed bool // the proof in hand is refused without a verify (no key for its level)
}

// set: `key` (32 bytes) verifies proofs for `level` (1..max_security_level; another is ignored)
pub fn (mut k Keys) set(level int, key &u8) {
	if level < 1 || level > uds.max_security_level {
		return
	}
	for i in 0 .. 32 {
		k.keys[level - 1][i] = unsafe { key[i] }
	}
}

// ops: the AuthOps verifying with `k`, which must outlive the server holding them
pub fn (mut k Keys) ops() uds.AuthOps {
	return uds.AuthOps{
		ctx:   unsafe { voidptr(&k) }
		keyed: keys_keyed
		start: keys_start
		step:  keys_step
	}
}

// keyed: LEVEL has a key
pub fn (k &Keys) keyed(level u8) bool {
	if level < 1 || level > uds.max_security_level {
		return false
	}
	for i in 0 .. 32 {
		if k.keys[level - 1][i] != 0 {
			return true
		}
	}
	return false
}

fn keys_keyed(ctx voidptr, level u8) bool {
	k := unsafe { &Keys(ctx) }
	return k.keyed(level)
}

// keys_start: begin verifying `proof` (64 bytes) under LEVEL's key as an Ed25519 signature over the
// application message — uds.auth_context, LEVEL, the challenge — never the bare challenge the
// bootloader's 0x29 signs (boot/prog.v), so neither a bootloader's proof nor another level's is
// accepted here
fn keys_start(ctx voidptr, level u8, challenge &u8, n int, proof &u8) {
	mut k := unsafe { &Keys(ctx) }
	k.failed = !k.keyed(level) // a level with no key verifies nothing
	if k.failed {
		return
	}
	mut key := [32]u8{}
	for i in 0 .. 32 {
		key[i] = k.keys[level - 1][i]
	}
	mut sig := [64]u8{}
	for i in 0 .. 64 {
		sig[i] = unsafe { proof[i] }
	}
	k.job.start(key, sig)
	k.job.update(&uds.auth_context[0], uds.auth_context.len)
	lv := [level]!
	k.job.update(&lv[0], 1)
	k.job.update(challenge, n)
}

// keys_step: the verify advanced by verify_step_mults multiplications
fn keys_step(ctx voidptr) uds.AuthVerdict {
	mut k := unsafe { &Keys(ctx) }
	if k.failed {
		return .invalid
	}
	if !k.job.step(verify_step_mults) {
		return .verifying
	}
	return if k.job.verified() { uds.AuthVerdict.valid } else { uds.AuthVerdict.invalid }
}
