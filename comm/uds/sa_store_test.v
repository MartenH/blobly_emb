module uds

// @verifies REQ-DIAG-065 REQ-DIAG-067 REQ-DIAG-068
// (the 0x27 state's record — each level's wrong keys since its last correct key, saturating at the
//  configured limit: restored at start-up as after a reset, a saturated count as a lockout from
//  boot, a record of another layout restoring nothing, a count of an unserved level arming the
//  delay once and dropped by the first pass; written only when it changes — a wrong key below the
//  limit, a correct key clearing a count — so at most the attempts per level between correct keys plus one per correct
//  key, whatever the resets, power cycles, refused and unconfirmed writes; a refused write changing
//  no answer and retried until the store holds the record; a pass's write reported for the NM sleep
//  choreography. Over a fake store — the real journal, with power cuts and a full journal, is
//  comm/diag/sa_persist_test.v.)

// SpStore is a RAM store: one block, the writes it accepted and tried, and the ways it fails — a
// refusal (nothing stored), or an UNCONFIRMED write (the bytes stored, false returned: a failed
// program the journal could not read back, which may have landed whole).
struct SpStore {
mut:
	cell        [16]u8
	len         int  // 0 = no record
	puts        int  // writes accepted
	tries       int  // writes asked for
	refuse      bool // every write refused
	unconfirmed bool // every write stored and reported refused
}

fn sp_put(ctx voidptr, _ u16, data &u8, len u16) bool {
	mut f := unsafe { &SpStore(ctx) }
	f.tries++
	if f.refuse {
		return false
	}
	for i in 0 .. int(len) {
		f.cell[i] = unsafe { data[i] }
	}
	f.len = int(len)
	if f.unconfirmed {
		return false
	}
	f.puts++
	return true
}

fn sp_get(ctx voidptr, _ u16, out &u8, cap u16) u16 {
	f := unsafe { &SpStore(ctx) }
	n := if f.len < int(cap) { f.len } else { int(cap) }
	for i in 0 .. n {
		unsafe {
			out[i] = f.cell[i]
		}
	}
	return u16(n)
}

const sp_retry_us = u64(1_000_000)

// sp_server: a server serving 0x27 levels 1 and 2 with the reference key, three attempts and a 1 s
// lockout, its state restored from `f` (a start-up), first ticked at `now` and in the extended session.
fn sp_server(mut f SpStore, now u64) Server {
	return sp_server_n(mut f, now, 0)
}

// sp_server_n: sp_server with `attempts` configured (0 = the default).
fn sp_server_n(mut f SpStore, now u64, attempts u8) Server {
	mut s := Server{}
	s.init(256)
	s.sa_attempts = attempts
	mut r := &ReferenceSecurity{}
	s.security = r.ops(u32(now) ^ 0x5A5A_1234)
	s.security_levels = 0x03
	s.sa_delay_us = 1_000_000
	s.serves_reset = true // the owner performs an answered ECUReset (a target)
	s.sa_store = SecurityStore{
		ctx:      unsafe { voidptr(&f) }
		put:      sp_put
		get:      sp_get
		id:       0x044E
		retry_us: sp_retry_us
	}
	s.restore_persisted_security()
	s.tick(now)
	sp_call(mut s, [u8(0x10), 0x03])
	return s
}

fn sp_call(mut s Server, req []u8) []u8 {
	mut resp := [64]u8{}
	n := s.handle(&req[0], req.len, &resp[0])
	mut out := []u8{}
	for i in 0 .. n {
		out << resp[i]
	}
	return out
}

// sp_key: a seed of `level` requested (relocking first) and answered right or wrong; the answer.
fn sp_key(mut s Server, level u8, right bool) []u8 {
	sp_call(mut s, [u8(0x10), 0x03])
	r := sp_call(mut s, [u8(0x27), 2 * level - 1])
	if r.len < 2 + seed_len || r[0] != 0x67 {
		return r
	}
	mut req := [u8(0x27), 2 * level]
	for b in r[2..] {
		req << if right { b ^ 0xFF } else { b ^ 0xFE }
	}
	return sp_call(mut s, req)
}

fn sp_record(counts []u8) []u8 {
	mut r := [sa_record_format, u8(max_security_level)]
	for i in 0 .. max_security_level {
		r << if i < counts.len { counts[i] } else { u8(0) }
	}
	return r
}

fn sp_store_with(rec []u8) SpStore {
	mut f := SpStore{}
	for i, b in rec {
		f.cell[i] = b
	}
	f.len = rec.len
	return f
}

fn sp_seed_answers(mut s Server) u8 {
	sp_call(mut s, [u8(0x10), 0x03])
	r := sp_call(mut s, [u8(0x27), 0x01])
	return if r[0] == 0x67 { u8(0) } else { r[2] }
}

fn sp_held(f &SpStore) []u8 {
	return f.cell[..f.len].clone()
}


// REQ-DIAG-067: the record is written only when it changes — a wrong key below the limit (its count,
// by the pass that answered it), a correct key clearing a count — and never by a correct key on a
// clear count, the lockout beyond the key that reached the limit, a lockout's end, wrong keys at
// the limit, a start-up, the delay a start-up arms or a reset.
fn test_the_security_state_is_written_only_when_it_changes() {
	mut f := SpStore{}
	mut s := sp_server(mut f, 1_000_000)
	s.persist_security(false)
	assert f.puts == 0, 'a clean start-up wrote'
	// a clean unlock: nothing changes, nothing is written
	assert sp_key(mut s, 1, true) == [u8(0x67), 0x02]
	s.persist_security(false)
	assert f.puts == 0, 'an unlock with nothing counted wrote'
	// a wrong key: its count, by the pass that answered it, once
	assert sp_key(mut s, 1, false) == [u8(0x7F), 0x27, 0x35]
	assert f.puts == 0, 'the request wrote: the pass writes'
	s.persist_security(false)
	assert f.puts == 1 && sp_held(&f) == sp_record([u8(1)])
	s.persist_security(false)
	assert f.puts == 1, 'a wrong key wrote twice'
	// the correct key clearing it: one write
	assert sp_key(mut s, 1, true) == [u8(0x67), 0x02]
	s.persist_security(false)
	assert f.puts == 2 && sp_held(&f) == sp_record([]u8{}), 'the correct key clearing a count'
	for attempt in 1 .. 4 {
		sp_key(mut s, 1, false)
		s.persist_security(false)
		assert f.puts == 2 + attempt, 'each wrong key below the limit, the lockout the third reaches'
	}
	assert sp_held(&f) == sp_record([u8(3)])
	assert sp_seed_answers(mut s) == 0x37
	s.tick(1_999_999)
	s.persist_security(false)
	s.tick(2_000_000)
	s.persist_security(false)
	assert f.puts == 5, 'the lockout ending wrote'
	// at the limit: the attempts again, answered as ever, nothing written
	for want in [u8(0x35), 0x35, 0x36] {
		assert sp_key(mut s, 1, false) == [u8(0x7F), 0x27, want]
		s.persist_security(false)
	}
	assert f.puts == 5, 'a wrong key at the limit wrote'
	// a reset with a count, the delay it arms, and that delay's end write nothing
	s.reset_state()
	s.persist_security(false)
	s.tick(3_100_000)
	s.persist_security(false)
	assert sp_seed_answers(mut s) == 0x37
	s.tick(4_200_000)
	s.persist_security(false)
	assert f.puts == 5, 'a reset with a count wrote'
	// a start-up restoring the count writes nothing, through the whole delay it arms
	mut t := sp_server(mut f, 100)
	for now in [u64(100), 500_000, 1_100_000, 1_100_001, 5_000_000] {
		t.tick(now)
		t.persist_security(false)
	}
	assert f.puts == 5, 'a start-up wrote'
	// the correct key at the limit: one clearing write
	assert sp_key(mut t, 1, true) == [u8(0x67), 0x02]
	t.persist_security(false)
	assert f.puts == 6 && sp_held(&f) == sp_record([]u8{})
	t.reset_state()
	t.persist_security(false)
	t.tick(5_100_000)
	t.persist_security(false)
	assert f.puts == 6
	assert sp_seed_answers(mut t) == 0, 'a reset after a correct key waited'
}

// REQ-DIAG-065: a restored count below the limit carries over and arms the delay from the first
// tick; a count at the limit runs the full delay from start-up, after which the level has its
// attempts again (and nothing is written, the record holding the count until a correct key); a
// clean record never waits.
fn test_a_restored_state_runs_as_after_a_reset() {
	mut f := sp_store_with(sp_record([u8(2)]))
	mut s := sp_server(mut f, 1_000_000)
	assert sp_seed_answers(mut s) == 0x37
	s.tick(1_999_999)
	assert sp_seed_answers(mut s) == 0x37
	s.tick(2_000_000)
	assert sp_key(mut s, 1, false) == [u8(0x7F), 0x27, 0x36], 'the count did not carry over'
	s.persist_security(false)
	assert f.puts == 1 && sp_held(&f) == sp_record([u8(3)])
	// a saturated count: a lockout from boot, then the attempts again
	mut g := sp_store_with(sp_record([u8(0), 3]))
	mut l := sp_server(mut g, 7_000_000)
	l.persist_security(false)
	assert g.puts == 0, 'a start-up over a saturated count wrote'
	assert sp_seed_answers(mut l) == 0x37, 'a saturated count did not run the delay'
	l.tick(7_999_999)
	l.persist_security(false)
	assert sp_seed_answers(mut l) == 0x37
	l.tick(8_000_000)
	l.persist_security(false)
	assert g.puts == 0, 'the delay end wrote'
	assert l.sa_since[1] == 3 && l.sa_failed[1] == 0
	for want in [u8(0x35), 0x35, 0x36] {
		assert sp_key(mut l, 2, false) == [u8(0x7F), 0x27, want]
		l.persist_security(false)
	}
	assert g.puts == 0, 'fresh attempts after a saturated count wrote'
	// a clean record: a seed at once
	mut c := sp_store_with(sp_record([]u8{}))
	mut k := sp_server(mut c, 0)
	assert sp_seed_answers(mut k) == 0
	mut e := SpStore{}
	mut n := sp_server(mut e, 0)
	assert sp_seed_answers(mut n) == 0
}

// REQ-DIAG-065 / REQ-DIAG-068 at a configured limit other than the default: the saturation, the
// restore's split between a carried count and a lockout, and the keys a start-up grants all follow
// `security_attempts` — 5 and 1.
fn test_the_record_follows_the_configured_limit() {
	// five attempts: the count rises to five and no further, one write per wrong key
	mut f := SpStore{}
	mut s := sp_server_n(mut f, 1_000_000, 5)
	for want in [u8(0x35), 0x35, 0x35, 0x35, 0x36] {
		assert sp_key(mut s, 1, false) == [u8(0x7F), 0x27, want]
		s.persist_security(false)
	}
	assert f.puts == 5 && sp_held(&f) == sp_record([u8(5)])
	s.tick(2_000_000)
	for want in [u8(0x35), 0x35, 0x35, 0x35, 0x36] {
		assert sp_key(mut s, 1, false) == [u8(0x7F), 0x27, want]
		s.persist_security(false)
	}
	assert f.puts == 5, 'a count at a limit of five rose past it'
	// a count of four below a limit of five carries over: after the delay one key, the limit's own
	mut a := sp_store_with(sp_record([u8(4)]))
	mut t := sp_server_n(mut a, 1_000_000, 5)
	assert sp_seed_answers(mut t) == 0x37
	t.tick(2_000_000)
	assert sp_key(mut t, 1, false) == [u8(0x7F), 0x27, 0x36], 'a power cycle bought attempts'
	// a count of three: two keys left
	mut b := sp_store_with(sp_record([u8(3)]))
	mut u := sp_server_n(mut b, 1_000_000, 5)
	u.tick(2_000_000)
	assert sp_key(mut u, 1, false) == [u8(0x7F), 0x27, 0x35]
	assert sp_key(mut u, 1, false) == [u8(0x7F), 0x27, 0x36]
	// one attempt: the first wrong key is the lockout, stored once; a start-up runs the delay and
	// grants the one key again, writing nothing
	mut c := SpStore{}
	mut v := sp_server_n(mut c, 1_000_000, 1)
	assert sp_key(mut v, 1, false) == [u8(0x7F), 0x27, 0x36]
	v.persist_security(false)
	v.tick(2_000_000)
	assert sp_key(mut v, 1, false) == [u8(0x7F), 0x27, 0x36]
	v.persist_security(false)
	assert c.puts == 1 && sp_held(&c) == sp_record([u8(1)])
	mut w := sp_server_n(mut c, 3_000_000, 1)
	assert sp_seed_answers(mut w) == 0x37
	w.tick(4_000_000)
	assert w.sa_failed[0] == 0 && w.sa_since[0] == 1
	assert sp_key(mut w, 1, false) == [u8(0x7F), 0x27, 0x36]
	w.persist_security(false)
	assert c.puts == 1
}

// REQ-DIAG-065: a record of another layout — format, level count, length (the old 11-byte layout
// with its lockout byte included) — restores nothing (no delay), and is not written away until a
// real change.
fn test_a_record_of_another_layout_restores_nothing() {
	base := sp_record([u8(2)])
	mut variants := [][]u8{}
	mut v := base.clone()
	v[0] = 2
	variants << v
	v = base.clone()
	v[1] = 7
	variants << v
	v = base.clone()
	v[1] = 9
	variants << v
	variants << base[..sa_record_len - 1].clone()
	v = base.clone()
	v << 0 // 11 bytes: the layout with a lockout byte
	variants << v
	for rec in variants {
		mut f := sp_store_with(rec)
		mut s := sp_server(mut f, 1_000_000)
		s.persist_security(false)
		assert f.puts == 0, 'a start-up over ${rec} wrote'
		assert sp_seed_answers(mut s) == 0, '${rec} restored a delay'
		assert sp_key(mut s, 1, false) == [u8(0x7F), 0x27, 0x35]
		s.persist_security(false)
		assert f.puts == 1 && sp_held(&f) == sp_record([u8(1)])
	}
}

// REQ-DIAG-065: a count of a level this firmware no longer serves arms the delay at start-up, as
// every stored count does, but is not restored (its correct key is refused, so nothing could clear
// it in RAM); the first pass writes the record without it, so the next start-up is clean.
fn test_a_count_of_a_level_no_longer_served_costs_one_start_up() {
	mut f := sp_store_with(sp_record([u8(0), 0, 0, 0, 3]))
	mut s := sp_server(mut f, 1_000_000)
	assert s.sa_since[4] == 0 && s.sa_failed[4] == 0, 'an unserved level kept its count'
	assert sp_seed_answers(mut s) == 0x37, 'a stored count did not arm the delay'
	s.persist_security(false)
	assert f.puts == 1 && sp_held(&f) == sp_record([]u8{}), 'the unserved count was not dropped'
	s.persist_security(false)
	assert f.puts == 1, 'the dropped record was written again'
	s.tick(2_000_000)
	assert sp_key(mut s, 1, true) == [u8(0x67), 0x02]
	s.persist_security(false)
	assert f.puts == 1, 'an unlock with nothing served counted wrote'
	s = sp_server(mut f, 3_000_000)
	assert sp_seed_answers(mut s) == 0, 'a start-up after the drop waited'
	s.persist_security(false)
	assert f.puts == 1, 'a clean start-up wrote'
}

// REQ-DIAG-065: a count above the limit (an update that lowered security_attempts) restores
// unclamped, as saturated: no start-up write, the full delay, the attempts again writing nothing,
// and a correct key writing one record of zeros.
fn test_a_lowered_limit_restores_as_saturated() {
	mut f := sp_store_with(sp_record([u8(5)]))
	mut s := sp_server(mut f, 1_000_000)
	s.persist_security(false)
	assert f.puts == 0
	assert s.sa_since[0] == 5, 'the stored count was clamped'
	assert sp_seed_answers(mut s) == 0x37
	s.tick(2_000_000)
	for want in [u8(0x35), 0x35, 0x36] {
		assert sp_key(mut s, 1, false) == [u8(0x7F), 0x27, want]
		s.persist_security(false)
	}
	assert f.puts == 0
	s.tick(3_000_000)
	assert sp_key(mut s, 1, true) == [u8(0x67), 0x02]
	s.persist_security(false)
	assert f.puts == 1 && sp_held(&f) == sp_record([]u8{})
}

// REQ-NVM-014's input: take_sa_wrote reports a write a PASS made (an NM owner re-runs its sleep
// choreography for it) — a count, a clear — not a flush's (the choreography that flushed covers it),
// not an unlock that changed nothing, not a refused write, and is cleared by being taken.
fn test_take_sa_wrote_reports_a_pass_write_once() {
	mut f := SpStore{}
	mut s := sp_server(mut f, 1_000_000)
	assert !s.take_sa_wrote(), 'a start-up reported a write'
	assert sp_key(mut s, 1, true) == [u8(0x67), 0x02]
	assert s.persist_security(false) && f.puts == 0
	assert !s.take_sa_wrote(), 'an unlock with nothing counted reported a write'
	sp_key(mut s, 1, false)
	assert s.persist_security(false) && f.puts == 1
	assert s.take_sa_wrote(), 'a count was not reported'
	assert !s.take_sa_wrote(), 'a taken write reported again'
	assert sp_key(mut s, 1, true) == [u8(0x67), 0x02]
	assert s.persist_security(true) && f.puts == 2 // the clear, by a flush
	assert !s.take_sa_wrote(), 'a flush write was reported'
	assert s.persist_security(false) && f.puts == 2 // nothing changed: no write, nothing to report
	assert !s.take_sa_wrote()
	f.refuse = true
	assert sp_key(mut s, 1, false) == [u8(0x7F), 0x27, 0x35]
	assert !s.persist_security(false)
	assert !s.take_sa_wrote(), 'a refused write was reported'
	f.refuse = false
	s.tick(1_000_000 + sp_retry_us)
	assert s.persist_security(false)
	assert f.puts == 3 && s.take_sa_wrote(), 'the retried write was not reported'
}

// REQ-DIAG-067: a write the store refuses changes no answer — the key judged, the count in RAM
// counting — and is retried no sooner than retry_us and at once by every flush, until the store
// holds the record as it then is; a refused clear keeps the unlock it follows and the count stored
// (a cut restores more, never less); and a flush ends the wait, so a wrong key straight after one
// that succeeded is written by its own pass.
fn test_a_refused_write_changes_no_answer_and_is_retried() {
	mut f := SpStore{
		refuse: true
	}
	now := u64(1_000_000)
	mut s := sp_server(mut f, now)
	for want in [u8(0x35), 0x35, 0x36] {
		assert sp_key(mut s, 1, false) == [u8(0x7F), 0x27, want], 'a refused write changed an answer'
		s.persist_security(false)
	}
	assert f.tries == 1, 'a pass inside retry_us tried the store'
	assert s.sa_since[0] == 3 && f.len == 0
	s.tick(now + sp_retry_us - 1)
	assert !s.persist_security(false)
	assert f.tries == 1, 'retried before retry_us'
	s.tick(now + sp_retry_us)
	assert !s.persist_security(false)
	assert f.tries == 2
	assert !s.persist_security(true)
	assert f.tries == 3, 'a flush waited'
	// the store takes writes again: the next attempt writes the state as it is now
	f.refuse = false
	s.tick(now + 2 * sp_retry_us)
	assert s.persist_security(false)
	assert f.puts == 1 && sp_held(&f) == sp_record([u8(3)])
	// a refused clear: the unlock stands and the count stays stored; the flush takes the clear
	s.tick(now + 2 * sp_retry_us + 1_000_000) // the lockout over
	assert sp_key(mut s, 1, true) == [u8(0x67), 0x02]
	f.refuse = true
	assert !s.persist_security(false)
	assert s.unlocked == 1 && s.sa_since[0] == 0 && sp_held(&f) == sp_record([u8(3)])
	f.refuse = false
	assert s.persist_security(true), 'the flush did not take the clear'
	assert f.puts == 2 && sp_held(&f) == sp_record([]u8{})
	// a refused write, then a flush that succeeds: the wait is over for the next pass
	f.refuse = true
	assert sp_key(mut s, 1, false) == [u8(0x7F), 0x27, 0x35]
	assert !s.persist_security(false)
	tries := f.tries
	f.refuse = false
	assert s.persist_security(true)
	assert f.tries == tries + 1 && sp_held(&f) == sp_record([u8(1)])
	assert sp_key(mut s, 1, false) == [u8(0x7F), 0x27, 0x35]
	assert s.persist_security(false), 'a flush left the retry wait'
	assert sp_held(&f) == sp_record([u8(2)])
}

// REQ-DIAG-065 / REQ-DIAG-067: while the store refuses, keys are judged and counted in RAM; a
// restart restores the record last accepted, so a count accepted before the refusal still costs the
// delay; once the store takes writes again, a power cycle after a wrong key costs the delay.
fn test_a_refusing_store_keeps_the_state_in_ram_and_a_restart_restores_the_last_accepted() {
	mut f := SpStore{}
	mut now := u64(1_000_000)
	mut s := sp_server(mut f, now)
	assert sp_key(mut s, 1, false) == [u8(0x7F), 0x27, 0x35]
	assert s.persist_security(false) && sp_held(&f) == sp_record([u8(1)])
	f.refuse = true
	assert sp_key(mut s, 1, false) == [u8(0x7F), 0x27, 0x35]
	assert !s.persist_security(false)
	assert sp_key(mut s, 1, false) == [u8(0x7F), 0x27, 0x36], 'a refusing store bought an attempt'
	assert !s.persist_security(false)
	now += 1000
	s = sp_server(mut f, now) // a power cut: the record last accepted
	assert s.sa_since[0] == 1 && s.sa_failed[0] == 1, 'restored ${s.sa_since[0]} / ${s.sa_failed[0]}'
	assert sp_seed_answers(mut s) == 0x37
	f.refuse = false
	now += 1_000_000
	s.tick(now)
	assert sp_key(mut s, 1, false) == [u8(0x7F), 0x27, 0x35]
	assert s.persist_security(false) && sp_held(&f) == sp_record([u8(2)])
	now += 1000
	s = sp_server(mut f, now)
	assert sp_seed_answers(mut s) == 0x37, 'a power cycle between guesses bought fresh attempts'
}

// REQ-DIAG-067: a write the store reports UNCONFIRMED may have landed, so after it the store is not
// known to hold anything and the next write goes out whatever the record then is — never skipped
// because the record matches the one last confirmed, which would leave a counted key behind a clear
// that landed, for a power cut to take back.
fn test_an_unconfirmed_write_is_written_again() {
	mut f := SpStore{}
	now := u64(1_000_000)
	mut s := sp_server(mut f, now)
	assert sp_key(mut s, 1, false) == [u8(0x7F), 0x27, 0x35]
	assert s.persist_security(false) && f.puts == 1
	assert sp_key(mut s, 1, true) == [u8(0x67), 0x02]
	f.unconfirmed = true
	assert !s.persist_security(false)
	assert sp_held(&f) == sp_record([]u8{}), 'the unconfirmed clear did not land'
	f.unconfirmed = false
	// RAM back at the record last confirmed
	assert sp_key(mut s, 1, false) == [u8(0x7F), 0x27, 0x35]
	ram := s.sa_record()
	assert ram[..] == sp_record([u8(1)])
	s.tick(now + sp_retry_us)
	assert s.persist_security(false)
	assert sp_held(&f) == sp_record([u8(1)]), 'a counted key left behind a clear that landed: ${sp_held(&f)}'
	s = sp_server(mut f, now + sp_retry_us + 1000)
	assert sp_seed_answers(mut s) == 0x37, 'a power cycle took a counted key back'
}

// sp_stored_counts: whether the store holds a record of this layout counting a served level (1, 2).
fn sp_stored_counts(f &SpStore) bool {
	return f.len == sa_record_len && f.cell[0] == sa_record_format
		&& f.cell[1] == u8(max_security_level) && (f.cell[2] != 0 || f.cell[3] != 0)
}

fn sp_next(x u32) u32 {
	mut r := x ^ (x << 13)
	r ^= r >> 17
	r ^= r << 5
	return r
}

// REQ-DIAG-068 / REQ-DIAG-067 / REQ-DIAG-065: over any sequence of seeds, right and wrong keys of two
// levels, ticks through lockouts, resets, answered ECUResets, power cycles, refused and unconfirmed
// writes and flushes, at the default limit and at 5 and 1: the store accepts no more writes than the
// record changed (outside a restart), at most (attempts + 1) per correct key plus attempts per level
// — no budget, no special flush; whenever a pass reports the state stored, the store holds the
// record in RAM; and a restart arms the delay exactly when the store holds a count of a served level.
fn test_writes_stay_within_the_attempts_and_one_per_unlock() {
	mut rng := u32(0xC0FF_EE11)
	for limit in [u8(0), 5, 1] {
		attempts := int(if limit == 0 { default_sa_attempts } else { limit })
		for round in 0 .. 40 {
			mut f := SpStore{}
			mut now := u64(1_000_000)
			mut s := sp_server_n(mut f, now, limit)
			mut unlocks := 0
			mut changes := 0
			for step in 0 .. 300 {
				at := 'limit ${attempts} round ${round} step ${step}'
				rng = sp_next(rng)
				r := rng
				level := u8(1 + (r >> 8) % 2)
				before := s.sa_record()
				mut restarted := false
				match r % 10 {
					0, 1, 2 {
						sp_key(mut s, level, false)
					}
					3 {
						if sp_key(mut s, level, true) == [u8(0x67), 2 * level] {
							unlocks++
						}
					}
					4, 5 {
						now += u64((r >> 4) % 1_500_000)
						s.tick(now)
					}
					6 {
						s.reset_state()
					}
					7 {
						// an ECUReset the server answers and the owner performs: its flush, the restart
						assert sp_call(mut s, [u8(0x11), 0x01]) == [u8(0x51), 0x01]
						s.persist_security(true)
						counted := sp_stored_counts(&f)
						now += 1000
						s = sp_server_n(mut f, now, limit)
						restarted = true
						assert (s.sa_delay_until == now + 1_000_000) == counted, '${at}: ECUReset over ${sp_held(&f)}'
					}
					8 {
						counted := sp_stored_counts(&f)
						now += 1000
						s = sp_server_n(mut f, now, limit) // a power cycle
						restarted = true
						assert (s.sa_delay_until == now + 1_000_000) == counted, '${at}: power cycle over ${sp_held(&f)}'
					}
					else {
						k := (r >> 12) % 4
						if k == 0 {
							f.refuse = !f.refuse
						} else if k == 1 {
							f.unconfirmed = !f.unconfirmed
						} else {
							s.persist_security(true)
						}
					}
				}
				if !restarted && s.sa_record() != before {
					changes++
				}
				if s.persist_security(false) {
					rec := s.sa_record()
					held := if f.len > 0 { sp_held(&f) } else { sp_record([]u8{}) }
					assert held == rec[..], '${at}: store ${held}, RAM ${rec}'
				}
				assert f.puts <= changes, '${at}: ${f.puts} writes for ${changes} changes'
				assert f.puts <= unlocks * (attempts + 1) + 2 * attempts, '${at}: ${f.puts} writes for ${unlocks} unlocks'
			}
		}
	}
}

// REQ-DIAG-068 / REQ-DIAG-065: a tester without the key — wrong keys to both levels, lockouts
// waited out, resets, power cycles and a journal refusing and taking writes between them, for ever,
// at the default limit and at 5 — writes at most the attempts per level, and once the store holds a
// count every power cycle costs the delay (nothing but a correct key clears it).
fn test_wrong_keys_alone_write_at_most_the_attempts_per_level() {
	mut rng := u32(0x5EED_0068)
	for limit in [u8(0), 5] {
		attempts := int(if limit == 0 { default_sa_attempts } else { limit })
		mut f := SpStore{}
		mut now := u64(1_000_000)
		mut s := sp_server_n(mut f, now, limit)
		mut wrong := 0
		mut delays := 0
		for _ in 0 .. 6000 {
			rng = sp_next(rng)
			r := rng
			match r % 6 {
				0, 1 {
					a := sp_key(mut s, u8(1 + (r >> 8) % 2), false)
					if a.len == 3 && (a[2] == 0x35 || a[2] == 0x36) {
						wrong++
					}
				}
				2 {
					now += 1_000_000
					s.tick(now)
				}
				3 {
					s.reset_state()
				}
				4 {
					if (r >> 12) % 4 == 0 {
						f.refuse = !f.refuse
					}
				}
				else {
					counted := sp_stored_counts(&f)
					now += 1000
					s = sp_server_n(mut f, now, limit)
					if counted {
						assert sp_seed_answers(mut s) == 0x37, 'a power cycle over a stored count bought fresh attempts'
						delays++
					}
				}
			}
			s.persist_security(false)
		}
		assert wrong > 300 && delays > 300
		assert f.puts <= 2 * attempts, '${f.puts} writes for ${wrong} wrong keys'
	}
}
