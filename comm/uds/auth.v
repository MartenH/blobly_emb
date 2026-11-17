module uds

// Authentication (0x29) in an APPLICATION server: ISO 14229-1's authentication with Challenge-
// Response (ACR), unidirectional, with Ed25519 — the other way to earn a security level, beside
// SecurityAccess (0x27). A node unlocks one way: its server serves 0x29 exactly when an AuthOps
// verify is injected, and then 0x27 is not served (service_supported). Both ways grant the SAME
// level — Server.unlocked, which every gate compares against — and both are relocked by the same
// events (every session entry, S3, a reset). A failed proof is a wrong key of its level: the same
// count, attempt limit, lockout delay and persisted record as 0x27 (sa_wrong; sa_store.v).
//
// Sub-functions served (docs/diagnostics.md §3.1 "Authentication (0x29)"):
//   00 deAuthenticate                       29 00                  -> 69 00 10
//   05 requestChallengeForAuthentication    29 05 cc alg[16]       -> 69 05 00 alg[16] 0020 challenge[32] 0000
//   06 verifyProofOfOwnershipUnidirectional 29 06 alg[16] 0040 proof[64] 0000 0000 -> 7F 29 78 ..., 69 06 12 alg[16] 0000
// cc (communicationConfiguration, the one manufacturer-specific byte) names the LEVEL the proof
// will unlock; alg is the Ed25519 object identifier. The proof is an Ed25519 signature over
// exactly the 32-byte challenge — the bootloader's message (boot/prog.v), so a tester signs once
// for both. The level is bound to the challenge at 05, so 06 carries no level. The 06 answer is
// ISO 14229-1:2020's: returnValue, the algorithmIndicator, lengthOfSessionKeyInfo (0, none).
//
// A verify costs about 10,300 field multiplications, far more than one comm pass may take (that
// pass carries the bus too), so 06 answers responsePending (0x78) and the verify runs a slice per
// pass behind AuthOps.step while the answer is owed (pending.v). The verdict is counted in the pass
// that reaches it and answered in the next one, after the owner has persisted the count (REQ-DIAG-
// 067: a count is in the journal before the answer reporting it leaves). A verify the owed answer
// gives up (its timeout, its transport gone) counts as a failed proof: a proof is spent when it is
// received, so abandoning one buys no attempt. A session entry mid-verify — only the other
// transport can cause one, every request being dropped meanwhile: its tester disconnecting while it
// owns the session, its answered reset — voids the proof uncounted and answers it 0x22 (auth_void),
// as an MCU restart mid-verify loses it uncounted: nothing about it was judged or answered. A level is granted only where the
// transport owing the answer can carry ownershipVerified (auth_owed); over DoIP that is the push
// slot (driver/doipnet push_max).

pub const auth_challenge_len = 32
pub const auth_proof_len = 64

// request and answer lengths, fixed: parsing is an exact-length check
pub const auth_deauth_len = 2
pub const auth_challenge_req_len = 19
pub const auth_proof_req_len = 88
pub const auth_challenge_answer_len = 55
pub const auth_proof_answer_len = 21
pub const auth_deauth_answer_len = 3

// offsets in the requests and the 05 answer — the ONE statement of the layout, which the parser
// and blobly_net's encoder mirror (the golden vectors in auth_test.v pin the bytes independently)
pub const auth_level_at = 2 // 05: communicationConfiguration, the level
pub const auth_alg05_at = 3 // 05: algorithmIndicator (16)
pub const auth_alg_at = 2 // 06: algorithmIndicator (16)
pub const auth_proof_len_at = 18 // 06: lengthOfProofOfOwnershipClient (2) = 0x0040
pub const auth_proof_at = 20 // 06: proofOfOwnershipClient (64)
pub const auth_cc_len_at = 84 // 06: lengthOfChallengeClient (2) = 0
pub const auth_ap_len_at = 86 // 06: lengthOfAdditionalParameter (2) = 0
pub const auth_answer_challenge_at = 21 // 05 answer: the challenge (after alg[16] and its length)
pub const auth_answer_alg_at = 3 // 05 and 06 answers: algorithmIndicator (16), after returnValue

// auth_verify_timeout_us: how long a 06's owed answer waits for its verify — a slice per pass, about
// 75 passes (udsauth.verify_step_mults): inside one responsePending's P2*server_max
pub const auth_verify_timeout_us = pending_repeat_us

// the sub-functions served
pub const auth_deauthenticate = u8(0x00)
pub const auth_request_challenge = u8(0x05)
pub const auth_verify_proof = u8(0x06)

// returnValue (authenticationReturnParameter)
pub const auth_request_accepted = u8(0x00)
pub const auth_ownership_verified = u8(0x12)
pub const auth_deauthenticated = u8(0x10)

// ISO 14229-1's authentication NRCs used here
pub const nrc_ownership_failed = u8(0x58) // ownershipVerificationFailed
pub const nrc_challenge_failed = u8(0x59) // challengeCalculationFailed

// ed25519_algorithm: the algorithmIndicator — the Ed25519 object identifier 1.3.101.112 in DER
// (06 03 2B 65 70), left-aligned and zero-padded to 16 bytes
pub const ed25519_algorithm = [u8(0x06), 0x03, 0x2B, 0x65, 0x70, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]!

// AuthVerdict: where a proof's verify stands (AuthOps.step)
pub enum AuthVerdict {
	verifying
	valid
	invalid
}

// AuthOps is the 0x29 seam. `keyed` answers whether LEVEL has a key (a level without one is refused
// 0x31 at 05); `start` begins verifying `proof` (auth_proof_len bytes) as a signature over the
// challenge (`n` bytes, copied — the server's may change after) under LEVEL's key; `step` advances
// that verify by a bounded slice and says where it stands — called once per pass while the answer
// is owed. comm/uds holds no key and no algorithm — comm/udsauth holds the keys and runs bcrypto's
// stepped verify. All three nil = 0x29 is not served (and 0x27 may be). The challenge comes from
// SecurityOps.seed, the source 0x27's seeds do.
pub struct AuthOps {
pub mut:
	ctx   voidptr
	keyed fn (ctx voidptr, level u8) bool = unsafe { nil }
	start fn (ctx voidptr, level u8, challenge &u8, n int, proof &u8) = unsafe { nil }
	step  fn (ctx voidptr) AuthVerdict = unsafe { nil }
}

// authenticates: this server unlocks with 0x29 rather than 0x27
pub fn (s &Server) authenticates() bool {
	return s.auth.keyed != unsafe { nil } && s.auth.start != unsafe { nil }
		&& s.auth.step != unsafe { nil }
}

// authentication (0x29): 00 / 05 / 06 in ISO 14229-1's order — length (0x13), the sub-function
// (0x12), its exact length and fixed length fields (0x13); then for 05 the algorithm and the level
// (0x31: 0, above 8, not served or without a key), the level's delay (0x37), the response capacity
// (0x14) and the challenge source (0x59); for 06 a challenge outstanding (0x24), the algorithm
// (0x31, the challenge kept), the level's delay (0x37: the challenge void, the proof neither verified
// nor counted — a challenge drawn before a lockout buys no proof during it), the response capacity
// (0x14, the challenge kept), then 0x78 and the verdict (0x58, or 0x36 on the last allowed attempt). 05 always answers (the challenge is the
// answer) and so does 06 (its 0x78 lifts the suppression, as ISO 14229-1 has it); 00 honours the
// suppress bit.
fn (mut s Server) authentication(req &u8, req_len int, resp &u8) int {
	if req_len < 2 {
		return negative(resp, 0x29, nrc_incorrect_length)
	}
	sub := unsafe { req[1] } & 0x7F
	suppress := unsafe { req[1] } & 0x80 != 0
	want := match sub {
		auth_deauthenticate { auth_deauth_len }
		auth_request_challenge { auth_challenge_req_len }
		auth_verify_proof { auth_proof_req_len }
		else { 0 }
	}
	if want == 0 {
		return negative(resp, 0x29, nrc_subfunction_not_supported)
	}
	if req_len != want {
		return negative(resp, 0x29, nrc_incorrect_length)
	}
	if sub == auth_verify_proof && (be16(req, auth_proof_len_at) != auth_proof_len
		|| be16(req, auth_cc_len_at) != 0 || be16(req, auth_ap_len_at) != 0) {
		return negative(resp, 0x29, nrc_incorrect_length)
	}
	match sub {
		auth_deauthenticate {
			// the requesting transport's unlock and exchange end (comm/diag keeps the other's): relocked
			// as a dropped unlock is (Server.relock), so a control or routine it gated ends with it
			s.relock(s.unlocked)
			s.sa_level = 0
			s.void_challenge()
			if suppress {
				return 0
			}
			unsafe {
				resp[0] = 0x69
				resp[1] = auth_deauthenticate
				resp[2] = auth_deauthenticated
			}
			return auth_deauth_answer_len
		}
		auth_request_challenge {
			return s.auth_challenge_for(req, resp)
		}
		else {
			return s.auth_verify(req, resp)
		}
	}
}

fn (mut s Server) auth_challenge_for(req &u8, resp &u8) int {
	level := unsafe { req[auth_level_at] }
	if !alg_is_ed25519(req, auth_alg05_at) || level == 0 || level > max_security_level
		|| s.security_levels & (u8(1) << (level - 1)) == 0 || !s.auth.keyed(s.auth.ctx, level) {
		return negative(resp, 0x29, nrc_request_out_of_range)
	}
	if s.sa_delayed(level) {
		return negative(resp, 0x29, nrc_time_delay_not_expired)
	}
	if s.cap() < auth_challenge_answer_len {
		return negative(resp, 0x29, nrc_response_too_long)
	}
	s.sa_level = 0 // a new 05 voids the challenge outstanding
	if !s.security.seed(s.security.ctx, &s.auth_challenge[0], auth_challenge_len) {
		s.void_challenge()
		return negative(resp, 0x29, nrc_challenge_failed)
	}
	mut zero := true
	for b in s.auth_challenge {
		if b != 0 {
			zero = false
		}
	}
	if zero {
		return negative(resp, 0x29, nrc_challenge_failed) // a source that draws nothing is broken
	}
	s.sa_level = level
	unsafe {
		resp[0] = 0x69
		resp[1] = auth_request_challenge
		resp[2] = auth_request_accepted
		for i in 0 .. 16 {
			resp[auth_answer_alg_at + i] = ed25519_algorithm[i]
		}
		resp[19] = 0x00
		resp[20] = u8(auth_challenge_len)
		for i in 0 .. auth_challenge_len {
			resp[auth_answer_challenge_at + i] = s.auth_challenge[i]
		}
		resp[auth_answer_challenge_at + auth_challenge_len] = 0x00 // lengthOfNeededAdditionalParameter
		resp[auth_answer_challenge_at + auth_challenge_len + 1] = 0x00
	}
	return auth_challenge_answer_len
}

fn (mut s Server) auth_verify(req &u8, resp &u8) int {
	if s.sa_level == 0 {
		return negative(resp, 0x29, nrc_request_sequence_error) // no challenge outstanding
	}
	if !alg_is_ed25519(req, auth_alg_at) {
		return negative(resp, 0x29, nrc_request_out_of_range) // the challenge stays
	}
	if s.sa_delayed(s.sa_level) {
		s.sa_level = 0
		s.void_challenge()
		return negative(resp, 0x29, nrc_time_delay_not_expired)
	}
	if s.cap() < auth_proof_answer_len {
		return negative(resp, 0x29, nrc_response_too_long) // the challenge stays
	}
	level := s.sa_level
	s.sa_level = 0 // one proof per challenge
	s.auth.start(s.auth.ctx, level, &s.auth_challenge[0], auth_challenge_len, unsafe { req +
		auth_proof_at })
	s.void_challenge()
	s.auth_level = level
	s.auth_decided = false
	s.auth_nrc = 0
	return s.go_pending(0x29, 0, auth_verify_proof, auth_verify_timeout_us, resp)
}

// auth_owed: the owed 06 — the verify advanced by one slice until its verdict is in, which is
// counted (or granted) in that pass and answered in the next (0 = not yet). `cap` is what the
// transport owing the answer carries: a valid proof unlocks only where ownershipVerified fits it —
// otherwise 0x14, nothing unlocked and nothing counted — so no tester is told a proof failed that
// unlocked the ECU.
fn (mut s Server) auth_owed(resp &u8, cap int) int {
	if s.auth_level == 0 {
		return negative(resp, 0x29, nrc_conditions_not_correct) // nothing being verified
	}
	if !s.auth_decided {
		match s.auth.step(s.auth.ctx) {
			.verifying {
				return 0
			}
			.valid {
				if cap < auth_proof_answer_len {
					s.auth_nrc = nrc_response_too_long
				} else {
					s.sa_granted(s.auth_level)
					s.auth_nrc = 0
				}
			}
			.invalid {
				s.auth_nrc = s.sa_wrong(s.auth_level, nrc_ownership_failed)
			}
		}
		s.auth_decided = true
		return 0 // answered in the next pass, once the owner has persisted the count
	}
	nrc := s.auth_nrc
	s.auth_clear()
	if nrc != 0 {
		return negative(resp, 0x29, nrc)
	}
	if cap < auth_proof_answer_len {
		// granted for a larger answer than this transport carries: never left unlocked, and relocked
		// as a dropped unlock is, so nothing it gated outlives it
		s.relock(s.unlocked)
		return negative(resp, 0x29, nrc_response_too_long)
	}
	unsafe {
		resp[0] = 0x69
		resp[1] = auth_verify_proof
		resp[2] = auth_ownership_verified
		for i in 0 .. 16 {
			resp[auth_answer_alg_at + i] = ed25519_algorithm[i]
		}
		resp[auth_answer_alg_at + 16] = 0x00 // lengthOfSessionKeyInfo: none
		resp[auth_answer_alg_at + 17] = 0x00
	}
	return auth_proof_answer_len
}

// auth_abandon: the owed 06 given up (pending.v owed_stop: its timeout, its transport gone) — a
// verify without its verdict counts as a failed proof, so abandoning one buys nothing
fn (mut s Server) auth_abandon() {
	if s.auth_level != 0 && !s.auth_decided {
		s.sa_wrong(s.auth_level, nrc_ownership_failed)
	}
	s.auth_clear()
}

// auth_void: the owed 06 ended by a session entry (stop_routines) — never its own tester's doing,
// since every request is dropped while the answer is owed — so a verify without its verdict is
// dropped uncounted, as a restart drops it: nothing about the proof is judged or answered but 0x22.
// A verdict already reached stays as it was applied (counted, or granted and relocked by the entry).
fn (mut s Server) auth_void() {
	s.auth_clear()
}

fn (mut s Server) auth_clear() {
	s.auth_level = 0
	s.auth_decided = false
	s.auth_nrc = 0
}

// void_challenge: the challenge bytes cleared (sa_level == 0 already makes them unanswerable)
fn (mut s Server) void_challenge() {
	for i in 0 .. auth_challenge_len {
		s.auth_challenge[i] = 0
	}
}

fn alg_is_ed25519(req &u8, at int) bool {
	for i in 0 .. 16 {
		if unsafe { req[at + i] } != ed25519_algorithm[i] {
			return false
		}
	}
	return true
}

fn be16(req &u8, at int) int {
	return unsafe { int(req[at]) << 8 | int(req[at + 1]) }
}
