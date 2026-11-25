module uds

// @verifies REQ-DIAG-120 REQ-DIAG-121 REQ-DIAG-122 REQ-DIAG-123 REQ-DIAG-124 REQ-DIAG-125
// @verifies REQ-DIAG-127 REQ-DIAG-105 REQ-DIAG-085
// (0x29 Authentication in an application server, over a FAKE stepped verify — the real Ed25519
//  verify is comm/udsauth's test: one way to unlock, the challenge's layout and source and every one
//  fresh, the proof answered 0x78 and verified a slice per pass while its answer is owed, unlocking
//  the level bound to it, single use and every voiding event, failed (and abandoned) proofs counted
//  with 0x27's limit and lockout before their answer, deAuthenticate, the NRC order, functional
//  silence, the default session, and the golden 0x29 06 request parsed at its offsets.)

// The golden vectors, committed byte for byte in blobly_emb (here and comm/udsauth) and blobly_net
// (blobly/uds/auth_vectors_test.v): the dev tester seed 20..3F, its public key, the fixed challenge
// 00..1F and the deterministic Ed25519 signature (RFC 8032) under the seed of the application message
// for level 1 — auth_context, 01, the challenge.
const gv_sig = [u8(0x9f), 0x70, 0xab, 0xb9, 0x8d, 0x37, 0x4d, 0x2c, 0x24, 0xa6, 0xfa, 0xd6, 0x17,
	0x91, 0xbb, 0x94, 0xec, 0xb5, 0xbc, 0xab, 0xac, 0xcc, 0x23, 0x60, 0x7d, 0x4a, 0xc1, 0x45, 0x08,
	0xef, 0xdc, 0x93, 0xb1, 0xe8, 0xa0, 0x80, 0x64, 0x5f, 0xb9, 0xe0, 0x05, 0xf4, 0x71, 0x8c, 0x5f,
	0x91, 0x88, 0x61, 0xce, 0xf2, 0x5a, 0x6e, 0x28, 0x6b, 0xb8, 0x8d, 0xd3, 0xa0, 0xb1, 0x8c, 0x22,
	0x7c, 0x7f, 0x0d]

// gv_req05: 0x29 05 for level 1 with the Ed25519 algorithmIndicator (19 bytes)
const gv_req05 = [u8(0x29), 0x05, 0x01, 0x06, 0x03, 0x2B, 0x65, 0x70, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0]

// gv_ans05: its answer for the challenge 00..1F (55 bytes)
fn gv_ans05() []u8 {
	mut a := [u8(0x69), 0x05, 0x00, 0x06, 0x03, 0x2B, 0x65, 0x70, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		0x00, 0x20]
	for i in 0 .. 32 {
		a << u8(i)
	}
	a << [u8(0), 0]
	return a
}

// gv_req06: 0x29 06 carrying the golden signature (88 bytes)
fn gv_req06() []u8 {
	mut r := [u8(0x29), 0x06, 0x06, 0x03, 0x2B, 0x65, 0x70, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x00,
		0x40]
	r << gv_sig
	r << [u8(0), 0, 0, 0]
	return r
}

fn ac(mut s Server, req []u8) []u8 {
	mut resp := [256]u8{}
	n := s.handle(&req[0], req.len, &resp[0])
	mut out := []u8{}
	for i in 0 .. n {
		out << resp[i]
	}
	return out
}

// a_started: an application server with one constant DID, in the default session
fn a_started() Server {
	mut s := Server{}
	s.dids[0] = Did{
		id:  0xF190
		len: 2
	}
	s.ndid = 1
	s.init(256)
	s.serves_reset = true
	return s
}

// a_secured: the same unlocking by 0x27 with the reference key, in the extended session
fn a_secured() Server {
	mut s := a_started()
	mut r := &ReferenceSecurity{}
	s.security = r.ops(0x1234_5678)
	s.security_levels = 0x01
	s.tick(1_000_000)
	ac(mut s, [u8(0x10), 0x03])
	return s
}

// AStore is a RAM journal block (sa_store.v's seam)
struct AStore {
mut:
	cell [16]u8
	len  int
	puts int
}

fn a_put(ctx voidptr, _ u16, data &u8, len u16) bool {
	mut f := unsafe { &AStore(ctx) }
	for i in 0 .. int(len) {
		f.cell[i] = unsafe { data[i] }
	}
	f.len = int(len)
	f.puts++
	return true
}

fn a_get(ctx voidptr, _ u16, out &u8, cap u16) u16 {
	f := unsafe { &AStore(ctx) }
	n := if f.len < int(cap) { f.len } else { int(cap) }
	for i in 0 .. n {
		unsafe {
			out[i] = f.cell[i]
		}
	}
	return u16(n)
}

fn a_record(count u8) []u8 {
	mut r := [sa_record_format, u8(max_security_level), count]
	for _ in 1 .. max_security_level {
		r << u8(0)
	}
	return r
}

// FakeAuth: a stepped verify that accepts exactly the proof `good` (or, with `bind`, exactly the
// challenge followed by 32 bytes 0xA5 — a proof valid for one challenge only) for a level whose bit
// is in `levels`, after `steps` steps; keyed for the levels in `keyed`. It records the level and
// challenge it was asked about, and how many steps it took.
struct FakeAuth {
mut:
	good      []u8
	bind      bool
	levels    u8 = 0xFF
	keyed     u8 = 0xFF
	steps     int = 1
	starts    int
	stepped   int
	level     u8
	challenge []u8
	proof     []u8
}

fn fake_keyed(ctx voidptr, level u8) bool {
	f := unsafe { &FakeAuth(ctx) }
	return level >= 1 && level <= 8 && f.keyed & (u8(1) << (level - 1)) != 0
}

fn fake_start(ctx voidptr, level u8, challenge &u8, n int, proof &u8) {
	mut f := unsafe { &FakeAuth(ctx) }
	f.starts++
	f.stepped = 0
	f.level = level
	f.challenge = unsafe { challenge.vbytes(n) }.clone()
	f.proof = unsafe { proof.vbytes(auth_proof_len) }.clone()
}

fn fake_step(ctx voidptr) AuthVerdict {
	mut f := unsafe { &FakeAuth(ctx) }
	f.stepped++
	if f.stepped < f.steps {
		return .verifying
	}
	if f.levels & (u8(1) << (f.level - 1)) == 0 {
		return .invalid
	}
	want := if f.bind { bound_proof(f.challenge) } else { f.good }
	return if f.proof == want { AuthVerdict.valid } else { AuthVerdict.invalid }
}

fn bound_proof(challenge []u8) []u8 {
	mut p := challenge.clone()
	for _ in 0 .. 32 {
		p << u8(0xA5)
	}
	return p
}

fn fake_ops(mut f FakeAuth) AuthOps {
	return AuthOps{
		ctx:   unsafe { voidptr(f) }
		keyed: fake_keyed
		start: fake_start
		step:  fake_step
	}
}

// a source drawing 00, 01, ... 1F each time (the golden challenge), counting its draws in `draws`
// when given a ctx
fn counting_seed(ctx voidptr, out &u8, n int) bool {
	if ctx != unsafe { nil } {
		mut d := unsafe { &int(ctx) }
		unsafe {
			*d = *d + 1
		}
	}
	for i in 0 .. n {
		unsafe {
			out[i] = u8(i)
		}
	}
	return true
}

fn zero_seed(_ voidptr, out &u8, n int) bool {
	for i in 0 .. n {
		unsafe {
			out[i] = 0
		}
	}
	return true
}

fn failing_seed(_ voidptr, _ &u8, _ int) bool {
	return false
}

// a source drawing a different challenge every time (an LCG kept in ctx)
fn varying_seed(ctx voidptr, out &u8, n int) bool {
	mut x := unsafe { &u32(ctx) }
	for i in 0 .. n {
		unsafe {
			*x = *x * 1103515245 + 12345
			out[i] = u8(*x >> 16)
		}
	}
	return true
}

// authed: an application server authenticating levels 1 and 2 (three attempts, a 1 s lockout) with
// the golden signature the one good proof, in the extended session
fn authed(mut f FakeAuth) Server {
	mut s := a_started()
	f.good = gv_sig.clone()
	s.security = SecurityOps{
		seed: counting_seed
	}
	s.auth = fake_ops(mut f)
	s.security_levels = 0x03
	s.sa_delay_us = 1_000_000
	s.tick(1_000_000)
	ac(mut s, [u8(0x10), 0x03])
	return s
}

fn req05(level u8) []u8 {
	mut r := gv_req05.clone()
	r[auth_level_at] = level
	return r
}

fn req06_with(sig []u8) []u8 {
	mut r := gv_req06()
	for i in 0 .. auth_proof_len {
		r[auth_proof_at + i] = sig[i]
	}
	return r
}

fn bad_sig() []u8 {
	mut b := gv_sig.clone()
	b[10] ^= 0x01
	return b
}

// gv_ans06: the 06 answer — ownershipVerified, the algorithmIndicator, lengthOfSessionKeyInfo 0
// (ISO 14229-1:2020; 21 bytes)
fn gv_ans06() []u8 {
	mut a := [u8(0x69), 0x06, 0x12, 0x06, 0x03, 0x2B, 0x65, 0x70, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
	a << [u8(0x00), 0x00]
	return a
}

// owed: the passes after a 06 answered 0x78 — tick, then pending_step as an owner's pump calls it,
// a pass at a time — until the final answer, returned; `passes` the passes it took, the last one
// included
fn owed(mut s Server) ([]u8, int) {
	mut resp := [256]u8{}
	for pass in 1 .. 1000 {
		s.tick(s.now_us + 1000)
		n := s.pending_step(&resp[0], 256)
		if n > 0 && !s.pending() {
			return resp[..n].clone(), pass
		}
	}
	assert false, 'the owed answer never came'
	return []u8{}, 0
}

// pr: a 06, answered responsePending, and its final answer
fn pr(mut s Server, req []u8) []u8 {
	assert ac(mut s, req) == [u8(0x7F), 0x29, 0x78], 'the 06 was not answered responsePending'
	ans, _ := owed(mut s)
	return ans
}

// REQ-DIAG-121 / 122: the golden exchange — 05 answers the challenge in its layout, 06 carrying the
// signature over it is parsed at auth_proof_at and answered 0x78, the verify asked about level 1 and
// the challenge, and ISO's 21-byte answer once it is valid; the level is unlocked.
fn test_the_golden_exchange_unlocks_the_level() {
	assert auth_context[..] == 'blobly uds 0x29 application v1\0'.bytes()
	assert auth_message_len == 64
	mut f := FakeAuth{}
	mut s := authed(mut f)
	assert ac(mut s, gv_req05) == gv_ans05()
	assert s.sa_level == 1
	assert pr(mut s, gv_req06()) == gv_ans06()
	assert f.starts == 1 && f.level == 1 && f.proof == gv_sig
	mut want := []u8{}
	for i in 0 .. 32 {
		want << u8(i)
	}
	assert f.challenge == want, 'the verify was not asked about the challenge'
	assert s.unlocked == 1
	// the gate opens like 0x27's
	s.dids[0].read_security = 1
	assert ac(mut s, [u8(0x22), 0xF1, 0x90])[0] == 0x62
}

// REQ-DIAG-122: the verify runs a slice per pass (the server's tick) while the answer is owed —
// every other request is dropped meanwhile; a valid verdict unlocks with its answer, and a failed
// one is counted in the pass that reaches it and answered in the next, so an owner persisting
// between the two writes the count before the 0x58 reporting it (REQ-DIAG-067).
fn test_the_verify_runs_a_slice_per_pass() {
	mut f := FakeAuth{
		steps: 5
	}
	mut s := authed(mut f)
	ac(mut s, gv_req05)
	assert ac(mut s, gv_req06()) == [u8(0x7F), 0x29, 0x78]
	assert s.pending()
	assert ac(mut s, [u8(0x3E), 0x00]).len == 0, 'a request was served while the proof is verified'
	mut resp := [256]u8{}
	for pass in 1 .. 5 {
		s.tick(s.now_us + 1000)
		assert f.stepped == pass && s.unlocked == 0
		assert s.pending_step(&resp[0], 256) == 0
		assert f.stepped == pass, 'the answer stepped the verify'
	}
	s.tick(s.now_us + 1000)
	assert f.stepped == 5 && s.auth_decided && s.unlocked == 0, 'unlocked before its answer'
	n := s.pending_step(&resp[0], 256)
	assert resp[..n] == gv_ans06() && !s.pending() && s.unlocked == 1
	s.tick(s.now_us + 1000)
	assert f.stepped == 5, 'the verify was stepped past its verdict'
	// a wrong proof: counted in the pass that decides it, answered in the next
	ac(mut s, req05(2))
	assert ac(mut s, req06_with(bad_sig())) == [u8(0x7F), 0x29, 0x78]
	for _ in 0 .. 5 {
		s.tick(s.now_us + 1000)
		assert s.pending_step(&resp[0], 256) == 0
	}
	assert s.sa_since[1] == 1, 'the count was not in place before the answer'
	s.tick(s.now_us + 1000)
	m := s.pending_step(&resp[0], 256)
	assert resp[..m] == [u8(0x7F), 0x29, 0x58]
}

// REQ-DIAG-122: the verify advances in the server's tick whether or not the transport owing the
// answer can take a response — a link busy for passes (DoIP waiting for the 0x78's acknowledgement,
// a CAN link sending) delays the answer, never the verify, so it cannot run a valid proof into the
// verify's timeout; one decided before the timeout and answered after it is still ownershipVerified,
// and not counted.
fn test_the_verify_advances_while_the_transport_is_busy() {
	mut f := FakeAuth{
		steps: 5
	}
	mut s := authed(mut f)
	ac(mut s, gv_req05)
	ac(mut s, gv_req06())
	for _ in 0 .. 10 {
		s.tick(s.now_us + 1000) // no pending_step: the transport cannot take a response
	}
	assert f.stepped == 5 && s.auth_decided, 'the verify waited for the transport'
	s.tick(s.now_us + auth_verify_timeout_us) // and stays busy past the verify's timeout
	assert s.pending() && s.sa_since[0] == 0, 'a valid proof was failed for a busy transport'
	mut resp := [256]u8{}
	n := s.pending_step(&resp[0], 256)
	assert resp[..n] == gv_ans06() && s.unlocked == 1 && s.sa_since[0] == 0
}

// REQ-DIAG-122 / 127: no level is unlocked without its ownershipVerified — whichever pass the
// transport owing the answer stops taking responses in (before the verdict, in its pass, after it),
// an answer given up at its timeout leaves the level locked, and a valid proof uncounted
fn test_no_unlock_stays_without_its_answer() {
	for free in [3, 4, 5, 6] {
		mut f := FakeAuth{
			steps: 5
		}
		mut s := authed(mut f)
		ac(mut s, gv_req05)
		ac(mut s, gv_req06())
		mut answered := []u8{}
		mut resp := [256]u8{}
		for pass in 1 .. 20 {
			s.tick(s.now_us + 1000)
			if pass < free {
				n := s.pending_step(&resp[0], 256) // the transport takes responses until `free`
				if n > 0 && !s.pending() {
					answered = resp[..n].clone()
				}
			}
		}
		mut unlocked := s.unlocked
		for _ in 0 .. 3 {
			s.tick(s.now_us + auth_verify_timeout_us) // given up: the timeout, then P2*server_max
			if s.pending() {
				unlocked = s.unlocked // S3 runs again only once the answer is no longer owed
			}
		}
		assert !s.pending(), 'free ${free}: never given up'
		if answered == gv_ans06() {
			assert unlocked == 1
		} else {
			assert answered.len == 0 && unlocked == 0, 'free ${free}: unlocked without its answer'
			assert s.sa_since[0] == 0, 'free ${free}: a valid proof was counted'
		}
	}
}

// REQ-DIAG-123: a proof whose verify is given up counts as a failed one — at its timeout (answered
// 0x22), with its transport gone — so abandoning a proof buys no attempt.
fn test_an_abandoned_verify_counts_as_a_failed_proof() {
	mut f := FakeAuth{
		steps: 1_000_000
	}
	mut s := authed(mut f)
	ac(mut s, gv_req05)
	ac(mut s, gv_req06())
	s.tick(s.now_us + auth_verify_timeout_us)
	assert s.sa_since[0] == 1, 'a timed-out verify was not counted'
	mut resp := [256]u8{}
	assert s.pending_step(&resp[0], 256) == 0, 'the 0x22 left in the pass that counted it'
	s.tick(s.now_us + 1000)
	n := s.pending_step(&resp[0], 256)
	assert resp[..n] == [u8(0x7F), 0x29, 0x22] && !s.pending()
	assert s.unlocked == 0
	ac(mut s, [u8(0x10), 0x03])
	ac(mut s, gv_req05)
	ac(mut s, gv_req06())
	s.pending_abandon()
	assert s.sa_since[0] == 2 && !s.pending(), 'a verify whose transport went was not counted'
	// and a verdict already counted is not counted again when its answer is abandoned
	f.steps = 1
	ac(mut s, [u8(0x10), 0x03])
	ac(mut s, req05(2))
	ac(mut s, req06_with(bad_sig()))
	s.tick(s.now_us + 1000)
	assert s.pending_step(&resp[0], 256) == 0
	assert s.sa_since[1] == 1
	s.pending_abandon()
	assert s.sa_since[1] == 1, 'a decided proof was counted twice'
}

// REQ-DIAG-127: a session entry mid-verify — only the other transport can cause one (every request
// is dropped while the answer is owed): its owner ending the session, its answered reset — voids the
// proof uncounted, answered 0x22; a verdict already reached stays counted
fn test_a_session_entry_voids_a_verify_uncounted() {
	mut f := FakeAuth{
		steps: 1_000_000
	}
	mut s := authed(mut f)
	mut resp := [256]u8{}
	for void in ['end_session', 'reset_state'] {
		ac(mut s, [u8(0x10), 0x03])
		ac(mut s, gv_req05)
		ac(mut s, gv_req06())
		s.tick(s.now_us + 1000)
		assert s.pending_step(&resp[0], 256) == 0
		if void == 'end_session' {
			s.end_session()
		} else {
			s.reset_state()
		}
		n := s.pending_step(&resp[0], 256)
		assert resp[..n] == [u8(0x7F), 0x29, 0x22] && !s.pending(), void
		assert s.sa_since[0] == 0 && s.sa_failed[0] == 0, '${void} counted an unjudged proof'
		s.tick(s.now_us + 1)
	}
	f.steps = 1
	ac(mut s, [u8(0x10), 0x03])
	ac(mut s, gv_req05)
	ac(mut s, req06_with(bad_sig()))
	s.tick(s.now_us + 1000)
	s.end_session()
	assert s.sa_since[0] == 1, 'a decided proof lost its count to the session entry'
}

// REQ-DIAG-120: one way to unlock — with AuthOps, 0x27 is not served; without, 0x29 is not.
fn test_one_way_to_unlock() {
	mut f := FakeAuth{}
	mut s := authed(mut f)
	assert s.service_supported(0x29) && !s.service_supported(0x27)
	assert ac(mut s, [u8(0x27), 0x01]) == [u8(0x7F), 0x27, 0x11]
	mut k := a_secured()
	assert k.service_supported(0x27) && !k.service_supported(0x29)
	assert ac(mut k, gv_req05) == [u8(0x7F), 0x29, 0x11]
	// both grant the same levels: Server.unlocked
	ac(mut s, req05(2))
	pr(mut s, gv_req06())
	assert s.unlocked == 2
}

// REQ-DIAG-121 / 122: every 05 draws a FRESH challenge, replacing the one outstanding, and a proof
// valid for an earlier challenge is refused against a later one — a sniffed 06 buys nothing.
fn test_every_challenge_is_fresh_and_an_old_proof_fails() {
	mut f := FakeAuth{
		bind: true
	}
	mut s := authed(mut f)
	mut lcg := u32(7)
	s.security = SecurityOps{
		ctx:  unsafe { voidptr(&lcg) }
		seed: varying_seed
	}
	a1 := ac(mut s, gv_req05)
	c1 := a1[auth_answer_challenge_at..auth_answer_challenge_at + 32].clone()
	p1 := bound_proof(c1)
	assert pr(mut s, req06_with(p1)) == gv_ans06()
	assert s.unlocked == 1
	a2 := ac(mut s, gv_req05)
	c2 := a2[auth_answer_challenge_at..auth_answer_challenge_at + 32].clone()
	assert c2 != c1, 'the same challenge was handed out twice'
	assert pr(mut s, req06_with(p1)) == [u8(0x7F), 0x29, 0x58], 'a replayed proof verified'
	// a new 05 replaces an outstanding challenge: the first one's proof no longer verifies
	a3 := ac(mut s, gv_req05)
	c3 := a3[auth_answer_challenge_at..auth_answer_challenge_at + 32].clone()
	ac(mut s, gv_req05)
	assert pr(mut s, req06_with(bound_proof(c3))) == [u8(0x7F), 0x29, 0x58], 'a replaced challenge was answerable'
}

// REQ-DIAG-121 / 122: a challenge serves one proof; a new 05, every session entry (the same
// session too), S3, a reset and deAuthenticate void it (06 then 0x24).
fn test_a_challenge_is_single_use_and_voided() {
	mut f := FakeAuth{}
	mut s := authed(mut f)
	assert ac(mut s, gv_req06()) == [u8(0x7F), 0x29, 0x24], 'a proof without a challenge'
	ac(mut s, gv_req05)
	pr(mut s, gv_req06())
	assert ac(mut s, gv_req06()) == [u8(0x7F), 0x29, 0x24], 'a challenge served two proofs'
	// a failed proof consumes its challenge too
	ac(mut s, gv_req05)
	assert pr(mut s, req06_with(bad_sig())) == [u8(0x7F), 0x29, 0x58]
	assert ac(mut s, gv_req06()) == [u8(0x7F), 0x29, 0x24], 'a failed proof left its challenge'
	// a new 05 replaces the challenge (level 2 bound), and its level is what the proof unlocks
	ac(mut s, gv_req05)
	ac(mut s, req05(2))
	pr(mut s, gv_req06())
	assert f.level == 2 && s.unlocked == 2
	for void in [[u8(0x10), 0x03], [u8(0x29), 0x00]] {
		ac(mut s, gv_req05)
		ac(mut s, void)
		assert ac(mut s, gv_req06()) == [u8(0x7F), 0x29, 0x24], 'not voided by ${void}'
	}
	ac(mut s, gv_req05)
	s.tick(1_000_000 + default_s3_us + 10) // S3
	ac(mut s, [u8(0x10), 0x03])
	assert ac(mut s, gv_req06()) == [u8(0x7F), 0x29, 0x24], 'not voided by S3'
	ac(mut s, gv_req05)
	s.reset_state()
	s.tick(s.now_us + 1)
	ac(mut s, [u8(0x10), 0x03])
	assert ac(mut s, gv_req06()) == [u8(0x7F), 0x29, 0x24], 'not voided by a reset'
}

// REQ-DIAG-120 / 122: the unlock is relocked like 0x27's: every session entry, S3, a reset.
fn test_the_unlock_is_relocked_like_security_access() {
	mut f := FakeAuth{}
	mut s := authed(mut f)
	ac(mut s, gv_req05)
	pr(mut s, gv_req06())
	assert s.unlocked == 1
	ac(mut s, [u8(0x10), 0x03])
	assert s.unlocked == 0, 'a session entry kept the unlock'
	ac(mut s, gv_req05)
	pr(mut s, gv_req06())
	s.reset_state()
	assert s.unlocked == 0
}

// REQ-DIAG-123: failed proofs are wrong keys of their level — 0x58, then 0x36 at the limit (which
// starts the lockout: 05 is 0x37 until the delay ends), a correct proof clears the count, and the
// count is the one 0x27's limit and record use (sa_since, carried across a reset by sa_restart).
fn test_failed_proofs_count_as_wrong_keys() {
	mut f := FakeAuth{}
	mut s := authed(mut f)
	for want in [nrc_ownership_failed, nrc_ownership_failed, nrc_exceeded_attempts] {
		ac(mut s, gv_req05)
		assert pr(mut s, req06_with(bad_sig())) == [u8(0x7F), 0x29, want]
	}
	// the third verdict's pass: its answer is held one pass (owed's 1 ms) for the count to persist
	verdict := s.now_us - 1000
	assert s.sa_since[0] == 3
	assert ac(mut s, gv_req05) == [u8(0x7F), 0x29, 0x37], 'no lockout'
	// the lockout is level 1's: level 2 still gets a challenge
	assert ac(mut s, req05(2))[0] == 0x69
	until := s.sa_delay_until[0]
	assert until == verdict + 1_000_000, 'the lockout is not security_delay_ms from the verdict'
	s.tick(until - 1)
	assert ac(mut s, gv_req05) == [u8(0x7F), 0x29, 0x37]
	s.tick(until + 1)
	ac(mut s, [u8(0x10), 0x03])
	ac(mut s, gv_req05)
	assert pr(mut s, req06_with(bad_sig())) == [u8(0x7F), 0x29, 0x58]
	assert s.sa_since[0] == 3, 'the count since the last correct proof rose past the limit'
	// a reset with a count costs the delay, as with 0x27 (sa_restart)
	s.reset_state()
	s.tick(s.now_us + 1)
	ac(mut s, [u8(0x10), 0x03])
	assert ac(mut s, gv_req05) == [u8(0x7F), 0x29, 0x37], 'a reset bought a fresh proof'
	s.tick(s.now_us + 1_000_001)
	ac(mut s, gv_req05)
	pr(mut s, gv_req06())
	assert s.unlocked == 1 && s.sa_since[0] == 0 && s.sa_failed[0] == 0, 'a correct proof did not clear the count'
}

// REQ-DIAG-124: 0x29 00 relocks and voids the challenge; suppressed, it is silent. A 06 with the
// suppress bit is still answered: its 0x78 lifts the suppression (ISO 14229-1).
fn test_deauthenticate_relocks() {
	mut f := FakeAuth{}
	mut s := authed(mut f)
	ac(mut s, gv_req05)
	pr(mut s, gv_req06())
	assert ac(mut s, [u8(0x29), 0x00]) == [u8(0x69), 0x00, 0x10]
	assert s.unlocked == 0
	ac(mut s, gv_req05)
	pr(mut s, gv_req06())
	assert ac(mut s, [u8(0x29), 0x80]).len == 0
	assert s.unlocked == 0
	// 06 suppressed: 0x78, then answered all the same
	ac(mut s, gv_req05)
	mut r := gv_req06()
	r[1] = 0x86
	assert pr(mut s, r) == gv_ans06() && s.unlocked == 1
	// 05 always answers, the bit set or not
	mut q := gv_req05.clone()
	q[1] = 0x85
	assert ac(mut s, q)[0] == 0x69
}

// REQ-DIAG-124, REQ-DIAG-105, REQ-DIAG-085: an unlock 0x29 grants or drops goes through the relock
// rule 0x27's does — a proof unlocking level 2 returns the controls level 1 gated, a deAuthenticate
// returns those its own level gated, and a control needing no level stays through both.
fn test_an_authentication_unlock_relocks_like_security_access() {
	mut f := FakeAuth{
		levels: 0x03
	}
	mut s := authed(mut f)
	for i, lv in [u8(0), 1, 2] {
		s.ios[i] = IoControl{
			did:      u16(0x0200 + i)
			width:    1
			lo:       0
			hi:       250
			params:   0x08
			sessions: in_extended
			security: lv
		}
	}
	s.nio = 3
	set := fn (mut s Server, did u16) []u8 {
		return ac(mut s, [u8(0x2F), u8(did >> 8), u8(did), 0x03, 9])
	}
	ac(mut s, req05(1))
	assert pr(mut s, gv_req06()) == gv_ans06() && s.unlocked == 1
	assert set(mut s, 0x0200)[0] == 0x6F && set(mut s, 0x0201)[0] == 0x6F
	// level 2 granted by a proof: level 1's control returned, the ungated one kept
	ac(mut s, req05(2))
	assert pr(mut s, gv_req06()) == gv_ans06() && s.unlocked == 2
	assert !s.io_on(1) && s.io_on(0)
	assert set(mut s, 0x0202)[0] == 0x6F
	// deAuthenticate: level 2's control returned with the unlock, the ungated one kept
	assert ac(mut s, [u8(0x29), 0x00]) == [u8(0x69), 0x00, 0x10]
	assert s.unlocked == 0 && !s.io_on(2) && s.io_on(0)
}

// REQ-DIAG-125: the NRC order.
fn test_the_nrc_order() {
	mut f := FakeAuth{}
	mut s := authed(mut f)
	assert ac(mut s, [u8(0x29)]) == [u8(0x7F), 0x29, 0x13]
	for sub in [u8(0x01), 0x02, 0x03, 0x04, 0x07, 0x08, 0x7F] {
		assert ac(mut s, [u8(0x29), sub]) == [u8(0x7F), 0x29, 0x12], 'sub 0x${sub.hex()}'
	}
	assert ac(mut s, [u8(0x29), 0x00, 0x00]) == [u8(0x7F), 0x29, 0x13]
	assert ac(mut s, gv_req05[..18]) == [u8(0x7F), 0x29, 0x13]
	assert ac(mut s, gv_req06()[..87]) == [u8(0x7F), 0x29, 0x13]
	// 06's length fields: a proof length other than 64, a client challenge, an additional parameter
	for at in [auth_proof_len_at + 1, auth_cc_len_at + 1, auth_ap_len_at + 1] {
		mut r := gv_req06()
		r[at] ^= 0x01
		assert ac(mut s, r) == [u8(0x7F), 0x29, 0x13], 'length field at ${at}'
	}
	// 05: the algorithm, a level 0 / above 8 / not served / without a key — 0x31
	f.keyed = 0x01 // level 2 is served but has no key
	mut alg := gv_req05.clone()
	alg[auth_alg05_at + 2] = 0x2C
	assert ac(mut s, alg) == [u8(0x7F), 0x29, 0x31]
	for level in [u8(0), 2, 3, 9] {
		assert ac(mut s, req05(level)) == [u8(0x7F), 0x29, 0x31], 'level ${level}'
	}
	f.keyed = 0xFF
	// a keyed level the server does not serve (level 3: security_levels 0x03) is refused on its own
	assert ac(mut s, req05(3)) == [u8(0x7F), 0x29, 0x31], 'an unserved keyed level got a challenge'
	// 06: no challenge (0x24) before the algorithm (0x31); the algorithm (0x31) before the response
	// capacity (0x14); either refused keeps the challenge
	mut alg6 := gv_req06()
	alg6[auth_alg_at] = 0x07
	assert ac(mut s, alg6) == [u8(0x7F), 0x29, 0x24]
	ac(mut s, gv_req05)
	s.resp_cap = auth_proof_answer_len - 1
	assert ac(mut s, alg6) == [u8(0x7F), 0x29, 0x31], 'the capacity answered before the algorithm'
	assert ac(mut s, gv_req06()) == [u8(0x7F), 0x29, 0x14]
	s.resp_cap = 256
	assert pr(mut s, gv_req06())[0] == 0x69, 'a refused algorithm or capacity voided the challenge'
	// 06 for a level whose lockout began after its challenge was drawn (over another transport —
	// comm/diag keeps one per transport): the algorithm (0x31) first, then 0x37 before the capacity,
	// the challenge void and the proof neither verified nor counted
	ac(mut s, gv_req05)
	s.sa_delay_until[0] = s.now_us + 1_000_000
	assert ac(mut s, alg6) == [u8(0x7F), 0x29, 0x31], 'the lockout answered before the algorithm'
	s.resp_cap = auth_proof_answer_len - 1
	starts := f.starts
	assert ac(mut s, gv_req06()) == [u8(0x7F), 0x29, 0x37], 'a proof was taken during the lockout'
	s.resp_cap = 256
	assert f.starts == starts && s.sa_since[0] == 0 && s.sa_failed[0] == 0
	assert ac(mut s, gv_req06()) == [u8(0x7F), 0x29, 0x24], 'the challenge outlived the lockout refusal'
	s.sa_delay_until[0] = 0
	// level 1 locked out: an algorithm or level refused is still 0x31 (before the lockout), and a
	// good request 0x37 (before the capacity)
	for _ in 0 .. 3 {
		ac(mut s, gv_req05)
		pr(mut s, req06_with(bad_sig()))
	}
	assert ac(mut s, gv_req05) == [u8(0x7F), 0x29, 0x37]
	assert ac(mut s, alg) == [u8(0x7F), 0x29, 0x31], 'the lockout answered before the algorithm'
	f.keyed = 0x02
	assert ac(mut s, gv_req05) == [u8(0x7F), 0x29, 0x31], 'the lockout answered before the key'
	f.keyed = 0xFF
	s.resp_cap = auth_challenge_answer_len - 1
	assert ac(mut s, gv_req05) == [u8(0x7F), 0x29, 0x37], 'the capacity answered before the lockout'
	// level 2, with a challenge outstanding: the capacity (0x14) before the source (0x59) — no draw,
	// and the challenge kept
	s.resp_cap = 256
	mut draws := 0
	s.security = SecurityOps{
		ctx:  unsafe { voidptr(&draws) }
		seed: counting_seed
	}
	ac(mut s, req05(2))
	assert draws == 1
	s.resp_cap = auth_challenge_answer_len - 1
	s.security.seed = failing_seed
	assert ac(mut s, req05(2)) == [u8(0x7F), 0x29, 0x14]
	s.resp_cap = 256
	s.security.seed = counting_seed
	assert draws == 1, 'a refused challenge request drew a challenge'
	assert pr(mut s, gv_req06())[0] == 0x69, 'a refused challenge request voided the outstanding one'
	// a source that fails, or draws all zeros: 0x59, and the challenge outstanding is void
	for bad in [failing_seed, zero_seed] {
		s.security.seed = counting_seed
		ac(mut s, req05(2))
		s.security.seed = bad
		assert ac(mut s, req05(2)) == [u8(0x7F), 0x29, 0x59]
		assert ac(mut s, gv_req06()) == [u8(0x7F), 0x29, 0x24], 'a failed challenge left one outstanding'
	}
}

// REQ-DIAG-121: not in the default session (0x7F), and a functional 0x29 is ignored outright.
fn test_default_session_and_functional() {
	mut f := FakeAuth{}
	mut s := authed(mut f)
	ac(mut s, [u8(0x10), 0x01])
	assert ac(mut s, gv_req05) == [u8(0x7F), 0x29, 0x7F]
	ac(mut s, [u8(0x10), 0x03])
	mut resp := [256]u8{}
	req := gv_req05.clone()
	assert s.handle_functional(&req[0], req.len, &resp[0]) == 0
	assert s.sa_level == 0, 'a functional 0x29 issued a challenge'
}

// REQ-DIAG-123 / 065: failed proofs are written to the 0x27 record — in the pass that decides them,
// before their answer — and restored across a power cycle, after which 05 is 0x37 until the delay
// ends; the record format unchanged.
fn test_failed_proofs_survive_a_power_cycle() {
	mut st := AStore{}
	mut f := FakeAuth{}
	f.good = gv_sig.clone()
	mut s := auth_store_server(mut st, mut f, 1_000_000)
	mut resp := [256]u8{}
	for i, want in [u8(0x58), 0x58] {
		ac(mut s, gv_req05)
		assert ac(mut s, req06_with(bad_sig())) == [u8(0x7F), 0x29, 0x78]
		s.tick(s.now_us + 1000) // the verdict, counted
		assert s.pending_step(&resp[0], 256) == 0, 'answered in the pass that counted it'
		s.persist_security(false) // the owner's pass: persisted before the answer
		assert st.puts == i + 1, 'the count was not written before its answer'
		s.tick(s.now_us + 1000)
		n := s.pending_step(&resp[0], 256)
		assert resp[..n] == [u8(0x7F), 0x29, want]
	}
	assert st.puts == 2 && st.cell[..st.len] == a_record(2)
	// the power cycle: a fresh server over the same store
	mut n := auth_store_server(mut st, mut f, 5_000_000)
	assert ac(mut n, gv_req05) == [u8(0x7F), 0x29, 0x37], 'a power cycle bought a fresh proof'
	n.tick(6_000_001)
	ac(mut n, [u8(0x10), 0x03])
	ac(mut n, gv_req05)
	assert pr(mut n, req06_with(bad_sig())) == [u8(0x7F), 0x29, 0x36], 'the count did not carry over'
}

// REQ-DIAG-123 / 067: a verify given up at its timeout is counted in that pass's tick, and its 0x22
// waits for the next pass — the owner's persist step writes the count before the answer reporting
// it leaves, on DoIP (whose push runs before the persist step in a pass) as on CAN
fn test_a_timed_out_proof_is_persisted_before_its_answer() {
	mut st := AStore{}
	mut f := FakeAuth{
		steps: 1_000_000
	}
	mut s := auth_store_server(mut st, mut f, 1_000_000)
	ac(mut s, gv_req05)
	ac(mut s, gv_req06())
	s.tick(s.now_us + auth_verify_timeout_us)
	assert s.sa_since[0] == 1 && st.puts == 0
	mut resp := [256]u8{}
	assert s.pending_step(&resp[0], 256) == 0, 'the 0x22 left before the count was persisted'
	s.persist_security(false)
	assert st.puts == 1 && st.cell[..st.len] == a_record(1)
	s.tick(s.now_us + 1000)
	n := s.pending_step(&resp[0], 256)
	assert resp[..n] == [u8(0x7F), 0x29, 0x22]
}

fn auth_store_server(mut st AStore, mut f FakeAuth, now u64) Server {
	mut s := Server{}
	s.init(256)
	s.security = SecurityOps{
		seed: counting_seed
	}
	s.auth = fake_ops(mut f)
	s.security_levels = 0x01
	s.sa_delay_us = 1_000_000
	s.sa_store = SecurityStore{
		ctx:      unsafe { voidptr(&st) }
		put:      a_put
		get:      a_get
		id:       0x044E
		retry_us: 1_000_000
	}
	s.restore_persisted_security()
	s.tick(now)
	ac(mut s, [u8(0x10), 0x03])
	return s
}

// REQ-DIAG-127: a valid proof is granted only where the transport owing its answer carries the
// 21-byte ownershipVerified — otherwise 0x14 and nothing unlocked (a DoIP push slot too small would
// tell the tester its proof failed while the ECU unlocked); its level's count is cleared at the
// verdict all the same, since the proof was correct, and the 0x14 waits a pass for that to persist
fn test_a_valid_proof_unlocks_only_where_its_answer_fits() {
	mut f := FakeAuth{}
	mut s := authed(mut f)
	mut resp := [256]u8{}
	// a failed proof first, so there is a count to clear
	ac(mut s, gv_req05)
	ac(mut s, req06_with(bad_sig()))
	s.tick(s.now_us + 1000)
	s.tick(s.now_us + 1000)
	assert s.pending_step(&resp[0], 256) == 3 && s.sa_since[0] == 1
	ac(mut s, gv_req05)
	assert ac(mut s, gv_req06()) == [u8(0x7F), 0x29, 0x78]
	cap := auth_proof_answer_len - 1
	s.tick(s.now_us + 1000) // the verdict
	assert s.unlocked == 0, 'granted before its answer'
	assert s.sa_since[0] == 0, 'a correct proof left its count standing'
	assert s.pending_step(&resp[0], cap) == 0, 'the 0x14 left in the pass that cleared the count'
	s.tick(s.now_us + 1000)
	n := s.pending_step(&resp[0], cap)
	assert resp[..n] == [u8(0x7F), 0x29, 0x14] && !s.pending()
	assert s.unlocked == 0 && s.sa_since[0] == 0 && s.sa_failed[0] == 0
}

// @verifies REQ-DIAG-127 — a verify still undecided at its timeout is given up there, counted and
// answered 0x22, even when the pass that reaches the timeout would have finished it: a late pass (a
// scheduling pause) never turns a verdict reached after the deadline into a timely one
fn test_a_verify_undecided_at_its_timeout_is_not_finished_late() {
	mut f := FakeAuth{
		steps: 3
	}
	mut s := authed(mut f)
	ac(mut s, gv_req05)
	assert ac(mut s, gv_req06()) == [u8(0x7F), 0x29, 0x78]
	mut resp := [256]u8{}
	for _ in 0 .. 2 {
		s.tick(s.now_us + 1000)
		assert s.pending_step(&resp[0], 256) == 0
	}
	assert f.stepped == 2 && !s.auth_decided
	s.tick(s.now_us + auth_verify_timeout_us) // the pause: the final slice would land past the deadline
	assert f.stepped == 2, 'the verify advanced past its deadline'
	assert s.sa_since[0] == 1 && s.unlocked == 0, 'a verdict reached late was taken as timely'
	assert s.pending_step(&resp[0], 256) == 0, 'the 0x22 left in the pass that counted it'
	s.tick(s.now_us + 1000)
	n := s.pending_step(&resp[0], 256)
	assert resp[..n] == [u8(0x7F), 0x29, 0x22] && !s.pending() && s.unlocked == 0
	// a verdict reached BEFORE the deadline, with only the transport late, is still the answer
	ac(mut s, [u8(0x10), 0x03])
	ac(mut s, gv_req05)
	ac(mut s, gv_req06())
	for _ in 0 .. 3 {
		s.tick(s.now_us + 1000)
	}
	assert s.auth_decided
	s.tick(s.now_us + auth_verify_timeout_us)
	assert s.pending() && s.pending_step(&resp[0], 256) == auth_proof_answer_len
	assert s.unlocked == 1
}

// @verifies REQ-DIAG-067 REQ-DIAG-123 — a correct proof clears its level's count in the pass that
// reaches the verdict and holds its answer to the next one, so the owner's persist step writes the
// cleared count before ownershipVerified leaves; the unlock still comes with the answer
fn test_a_valid_proof_clears_the_persisted_count_before_its_answer() {
	mut st := AStore{}
	mut f := FakeAuth{}
	f.good = gv_sig.clone()
	mut s := auth_store_server(mut st, mut f, 1_000_000)
	ac(mut s, gv_req05)
	ac(mut s, req06_with(bad_sig()))
	s.tick(s.now_us + 1000)
	s.persist_security(false)
	s.tick(s.now_us + 1000)
	mut resp := [256]u8{}
	assert s.pending_step(&resp[0], 256) == 3 && st.cell[..st.len] == a_record(1)
	// the correct proof
	ac(mut s, gv_req05)
	ac(mut s, gv_req06())
	s.tick(s.now_us + 1000) // the verdict
	assert s.unlocked == 0, 'granted before its answer'
	assert s.pending_step(&resp[0], 256) == 0, 'ownershipVerified left before its cleared count was persisted'
	s.persist_security(false)
	assert st.cell[..st.len] == a_record(0), 'the cleared count was not written at the verdict'
	s.tick(s.now_us + 1000)
	n := s.pending_step(&resp[0], 256)
	assert resp[..n] == gv_ans06() && s.unlocked == 1
	// a correct proof with nothing counted writes nothing and waits for nothing
	puts := st.puts
	ac(mut s, [u8(0x10), 0x03])
	ac(mut s, gv_req05)
	ac(mut s, gv_req06())
	s.tick(s.now_us + 1000)
	assert s.pending_step(&resp[0], 256) == auth_proof_answer_len
	s.persist_security(false)
	assert st.puts == puts
}
