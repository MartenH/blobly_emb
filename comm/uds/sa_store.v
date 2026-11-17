module uds

// The SecurityAccess (0x27) state a target keeps across a power cycle and every reset
// (docs/diagnostics.md §3.1, REQ-DIAG-065/067/068): per level, the wrong keys since that level's
// last correct key, counted up to the attempt limit and no further, in ONE record of the node's NvM
// journal, written through an injected seam (SecurityStore) so comm/uds carries no C and imports no
// journal — the comm thread's glue points it at the journal, the host bridge leaves it nil (it has
// no power cycle: the count stays in RAM).
//
// The record states its layout EXACTLY, never as a hash (comm/param's rule): a hash of any width
// can be met by a constructed collision, so the header is the identity —
//
//   [ format (sa_record_format) | level count (max_security_level) | each level's wrong keys since
//     its last correct key, levels 1 .. max_security_level, rising to the attempt limit ]
//
// and a record whose length or header differs from this firmware's — another format, another
// max_security_level — restores NOTHING (no delay, as a clean boot), never misread. A count at the
// limit IS the lockout: no byte says one is running, and no clock is in the record.
//
// It is written when it changes, and the record makes that the whole rule: a wrong key raises its
// level's count while the count is below the limit, and a correct key clears a non-zero count —
// nothing else changes a byte. Not a wrong key at the limit, not the lockout's start beyond the key
// that reached the limit (that rise is the lockout), not its end, a start-up, the delay a start-up
// arms or an ECUReset (the one start-up write drops a count of a level a firmware update stopped
// serving); a correct key on a clear count writes nothing either. So per level at most
// security_attempts writes between two correct keys, and one by a correct key that follows a wrong
// one: a tester without the key writes at most security_attempts records per level until an
// authorised unlock, however many keys, resets and power cycles — no budget is needed, and the wear
// check counts the writes per unlock (tools/loom2v gen_wear.v). The write is the pass's persist step,
// after the pass's requests, so a count is in the journal before the 0x35 / 0x36 reporting it is
// pumped onto CAN; the journal is then current after every accepted write, and an ECUReset or the
// programming handoff needs no special flush. The price is stated: a count at the limit stays stored
// until that level's correct key, so every start-up meanwhile runs the full delay — what waiting
// would have cost, never more.
//
// A write the journal refuses changes no answer: the key was judged, and the count in RAM counts. It
// is retried after `retry_us`, and at once by every flush, until the store holds the record. Nothing
// here erases flash (REQ-DIAG-062: an erase would stall a single-bank MCU — or the H755's CM4
// executing from bank 2 — for the sector's erase time), so a journal another writer filled while its
// partner waits for an erase refuses until the node's next erase point: the recovery pass of the
// flush before an ECUReset, a sleep edge with NM, the boot without NM. Until then the changes are in
// RAM only, and a power cut or a reset the server did not perform restores the record last accepted
// (docs/nvm.md "The 0x27 failed-key state"). A journal that refuses for good (a failed mount, more
// blocks in flash than pool rows) keeps the state in RAM only, as it keeps no fault memory or coding.
// The bound counts the writes the store ACCEPTED: a put reported unconfirmed is retried like a
// refusal, and if it had landed the retry falls outside the bound (a flash fault, not a tester's
// doing).

pub const sa_record_format = u8(1)
pub const sa_record_len = 2 + max_security_level // format, level count, the counts

// SecurityStore is the journal seam: `put` replaces the block's value (false = refused, or
// UNCONFIRMED: the next write goes out whatever it holds), `get` reads it (its length, 0 = absent).
// A nil `put` = the state is kept in RAM only (the host bridge).
pub struct SecurityStore {
pub mut:
	ctx      voidptr
	put      fn (ctx voidptr, id u16, data &u8, len u16) bool = unsafe { nil }
	get      fn (ctx voidptr, id u16, out &u8, cap u16) u16   = unsafe { nil }
	id       u16 // the block: fixed, so no firmware update moves or prunes it
	retry_us u64 // a refused write waits this long before the next attempt (a flush does not)
}

// sa_record: the record of the state as it is now.
pub fn (s &Server) sa_record() [sa_record_len]u8 {
	mut r := [sa_record_len]u8{}
	r[0] = sa_record_format
	r[1] = u8(max_security_level)
	for i in 0 .. max_security_level {
		r[2 + i] = s.sa_since[i]
	}
	return r
}

// sa_same: whether `r` is the record last stored. A loop: the target has no heap to compare with.
fn (s &Server) sa_same(r [sa_record_len]u8) bool {
	for i in 0 .. sa_record_len {
		if r[i] != s.sa_stored[i] {
			return false
		}
	}
	return true
}

// restore_persisted_security takes the state back from the store, at start-up, after init and
// before the first request, by the rule a reset follows (sa_restart), for the levels this firmware
// serves: a count c below the attempt limit carries over as the lockout count and arms the delay —
// from boot, since the clock that timed it did not survive — as after an ECU reset; a count at or
// above the limit is a lockout: the full delay from boot, after which the level has its attempts
// again; either way the count since the last correct key is kept as stored, never clamped, so the
// record in RAM is what flash holds and a start-up writes nothing; 0 is a clean boot. A non-zero
// count of a level this firmware no longer serves arms the delay too (as any stored count does) but
// is not restored: its correct key is refused, so nothing could clear it in RAM. The first pass then
// writes the record without it (one write per such firmware update), so it costs one start-up's
// delay, never one at every start-up. An absent record, or one of another length or header, restores
// nothing. The record of what WAS restored becomes the last stored one.
pub fn (mut s Server) restore_persisted_security() {
	mut unserved := false
	if s.sa_store.get != unsafe { nil } {
		mut b := [sa_record_len + 1]u8{} // one byte more: an overlong record reads as such
		n := s.sa_store.get(s.sa_store.ctx, s.sa_store.id, &b[0], u16(sa_record_len + 1))
		if int(n) == sa_record_len && b[0] == sa_record_format && b[1] == u8(max_security_level) {
			for i in 0 .. max_security_level {
				if s.security_levels & (u8(1) << i) != 0 {
					s.sa_since[i] = b[2 + i]
				} else if b[2 + i] != 0 {
					s.sa_arm_delay = true
					unserved = true
				}
			}
			s.sa_restart()
		}
	}
	s.sa_stored = s.sa_record()
	s.sa_has_stored = !unserved // an unserved count: the first pass writes the record without it
}

// persist_security writes the record when it differs from the one last stored, or the store is not
// known to hold it, and returns whether the store holds the state as it is. Without `flush` (once
// per owner pass, after the pass's requests and tick, before the CAN answer is pumped) a refused
// write waits `retry_us` before the next attempt; a flush (a quiet point: a sleep edge, before an
// ECUReset) always tries, and ends the wait for the writes after it (its choreography may have
// erased). Neither erases: the flush before an ECUReset and at a sleep edge has its own
// erase-recovery pass around this call. A refused or unconfirmed write leaves the store not known
// to hold anything, so the next attempt goes out whatever the record then is.
pub fn (mut s Server) persist_security(flush bool) bool {
	if s.sa_store.put == unsafe { nil } {
		return true
	}
	if flush {
		s.sa_retry_at = 0 // a quiet point may have made room: the writes after it try at once
	}
	r := s.sa_record()
	if s.sa_has_stored && s.sa_same(r) {
		return true
	}
	if s.now_us < s.sa_retry_at {
		return false
	}
	if s.sa_put(r, flush) {
		return true
	}
	s.sa_has_stored = false // refused, or unconfirmed: the next write goes out whatever it holds
	s.sa_retry_at = s.now_us + s.sa_store.retry_us
	return false
}

// sa_put: one write of `r`, recorded as stored when the store accepts it. A flush's write is
// covered by the choreography that asked for it, so only a pass's write is noted for take_sa_wrote.
fn (mut s Server) sa_put(r [sa_record_len]u8, flush bool) bool {
	if !s.sa_store.put(s.sa_store.ctx, s.sa_store.id, &r[0], u16(sa_record_len)) {
		return false
	}
	for i in 0 .. sa_record_len {
		s.sa_stored[i] = r[i]
	}
	s.sa_has_stored = true
	if !flush {
		s.sa_wrote = true
	}
	return true
}

// take_sa_wrote: whether a pass wrote the record since the last call (an NM owner re-runs its
// flush choreography for a write made in bus sleep, so the clean marker covers it, REQ-NVM-014).
pub fn (mut s Server) take_sa_wrote() bool {
	w := s.sa_wrote
	s.sa_wrote = false
	return w
}
