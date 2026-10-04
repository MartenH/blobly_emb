module fault

// Persistence of the fault memory (docs/diagnostics.md §3.3, R6b): what survives a reset and a
// power loss, kept in an injected Store — the NvM journal on a ThreadX target (nvm.Journal through
// the generated seam), nothing on the host. Two kinds of value:
//
//   the STATUS IMAGE, one value under one fixed block id: every DTC's persisted status bits, its
//   counters, the current operation cycle's per-DTC flags, and which DTC holds a stored snapshot.
//   ONE value, so a group clear, a displacement and a cycle boundary are each one atomic write;
//
//   TWO SNAPSHOT blocks, A and B, per DTC that declares `freeze` (their ids derived from the DTC
//   and the snapshot's schema): the DTC, its allocation stamp, the schema's fingerprint and the
//   record body — or a 1-byte TOMBSTONE once released, so a released block stops occupying
//   journal space.
//
// THE INVARIANT: no block the last COMMITTED image claims is ever written or tombstoned; a block is
// released only by a committed image that no longer claims it. It holds by construction: each
// fault has TWO snapshot blocks, A and B; the image records which one it claims; a capture always
// writes the one the committed image does not claim (entry.v allocate), and a tombstone is written
// only for a block the committed image does not claim and no captured snapshot is waiting in. So
// a power cut anywhere restores a committed image with every block it claims intact — whether the
// DTC was displaced and reacquired, cleared, aged, or dropped by an update that lowered `entries`.
//
// A snapshot is written BEFORE the image that claims it, and a freed one is tombstoned only AFTER
// the image that no longer claims it is durable — so the image is the one authority: a power cut
// between the two writes restores either the old pair or the new one, never a claim of a snapshot
// that is not there, and an interrupted displacement loses neither entry (the old image still
// claims the victim, whose block is untouched until the swap is durable).
//
// What survives (ISO 14229-1 D.2: the bits a DTC carries across power-up): pendingDTC,
// confirmedDTC, testNotCompletedSinceLastClear and testFailedSinceLastClear, and the counters.
// testFailed is not stored — a DTC begins every power-up untested-failed, as AUTOSAR's default
// status storage does — and the two this-operation-cycle bits restart with the cycle. The cycle
// that power interrupted is ended at restore with the flags it had collected (tested, failed), so
// pending clears and aging counts across a power cycle exactly as across an orderly cycle end.
//
// Write budget. Nothing is written per debounce step; the image is rewritten only when what it
// stores changes, which the status rules bound PER OPERATION CYCLE: per DTC, at its first completed
// test (testNotCompletedSinceLastClear, the cycle's tested flag), at its first failure (pending,
// testFailedSinceLastClear, confirmed, the failed-cycle counter), and at the cycle's end (pending
// cleared, aging) — plus once at each cycle start and end, and at each tester clear and 0x85 change
// (the image records the setting, so a cycle cut with it off ends as it would have then). Changes in one
// owner pass coalesce into one write. A later occurrence in the same cycle changes only the
// occurrence counter, which is DEFERRED: written with the next image write or at the next flush (a
// sleep edge, an ECUReset), never on its own — so an intermittent fault costs no write per
// occurrence, and a power cut can lose the occurrences counted since that cycle's first failure,
// never more and never doubled. A snapshot block is written once per allocation (at most one per
// DTC per cycle: an entry that failed this cycle cannot be displaced) and tombstoned once when
// freed. A refused write is retried no sooner than `retry_us` later.

pub const image_version = u8(3) // 3: which of a DTC's two snapshot blocks is claimed (2: the setting bit and fingerprints)
pub const image_rec = 8 // bytes per DTC in the image
pub const max_image = 2 + max_faults * image_rec
pub const snap_hdr = 9 // a snapshot block: DTC (3), stamp (4), schema fingerprint (2), then the record body
pub const max_block = max_image // the larger of an image and a snapshot block (test_the_scratch_holds_either)

// the status bits the image keeps
pub const persisted_bits = pending | confirmed | not_completed_since_clear | failed_since_clear

// the image's per-DTC flag byte: the persisted bits in their own positions, and beside them
const img_tested = u8(0x01) // tested in the cycle in progress
const img_failed = u8(0x02) // failed in the cycle in progress
const img_snapshot = u8(0x40) // holds a stored snapshot
const img_block_b = u8(0x80) // ... in its block B (else A)
const img_cycle_open = u8(0x01) // image byte 1: an operation cycle was in progress
const img_setting_off = u8(0x02) // image byte 1: DTC setting was off (0x85) — so was its end

// Store is the persistence seam: `put` replaces a block's value (false = refused, nothing
// changed), `get` reads it (its length, 0 = absent). Nil `put` = RAM only.
pub struct Store {
pub mut:
	ctx      voidptr
	put      fn (ctx voidptr, id u16, data &u8, len u16) bool
	get      fn (ctx voidptr, id u16, out &u8, cap u16) u16
	id       u16 // the status image's block
	retry_us u64 // a refused automatic write waits this long before the next attempt
}

fn (m &Memory) stored() bool {
	return m.store.put != unsafe { nil } && m.store.get != unsafe { nil }
}

// image builds the status image into m.scratch and returns its length. With `clearing`, the
// DTCs `group` names are written as a clear leaves them (0x14's image, built before RAM changes).
fn (mut m Memory) image(clearing bool, group u32) int {
	m.scratch[0] = image_version
	m.scratch[1] = (if m.cycle_active { img_cycle_open } else { u8(0) }) | (if m.setting_off {
		img_setting_off
	} else {
		u8(0)
	})
	for i in 0 .. m.n {
		s := &m.slots[i]
		o := 2 + i * image_rec
		m.scratch[o] = u8(s.dtc >> 16)
		m.scratch[o + 1] = u8(s.dtc >> 8)
		m.scratch[o + 2] = u8(s.dtc)
		if clearing && (group == 0xFFFFFF || s.dtc == group) {
			m.scratch[o + 3] = status_cleared & persisted_bits
			for b in 4 .. image_rec {
				m.scratch[o + b] = 0
			}
			continue
		}
		mut f := s.status & persisted_bits
		if s.tested_cycle {
			f |= img_tested
		}
		if s.failed_cycle {
			f |= img_failed
		}
		if s.entry != 0 && m.entries[s.entry - 1].durable {
			f |= img_snapshot
			if m.entries[s.entry - 1].blk == 2 {
				f |= img_block_b
			}
		}
		m.scratch[o + 3] = f
		m.scratch[o + 4] = s.failed_cycles
		m.scratch[o + 5] = s.aging_count
		m.scratch[o + 6] = u8(s.occurrence >> 8)
		m.scratch[o + 7] = u8(s.occurrence)
	}
	return 2 + m.n * image_rec
}

// image_change compares the built image (m.scratch[0..n]) with the durable one: (anything
// differs, only occurrence counters differ).
fn (m &Memory) image_change(n int) (bool, bool) {
	if n != m.img_len {
		return true, false
	}
	mut any := false
	mut other := false
	for b in 0 .. n {
		if m.scratch[b] != m.img[b] {
			any = true
			if b < 2 || (b - 2) % image_rec < 6 {
				other = true
			}
		}
	}
	return any, any && !other
}

// commit_image: the built image is durable — it becomes the one the store holds, and every slot's
// claim follows it.
fn (mut m Memory) commit_image(n int) {
	for b in 0 .. n {
		m.img[b] = m.scratch[b]
	}
	m.img_len = n
	for i in 0 .. m.n {
		m.slots[i].claim = claim_of(m.img[2 + i * image_rec + 3])
		m.slots[i].claim_ok = m.slots[i].claim != 0 // an image claims only snapshots written whole
	}
}

// persist writes what changed: unwritten snapshots, then — once all of them are in — the image
// (deferred when only occurrence counters moved, unless `flush`), then the tombstones the durable
// image allows. Returns true when
// the store holds everything (deferred counters included). Without `flush` a refused write holds
// every write until `retry_us` has passed; a flush always tries. Call once per owner pass, and
// with flush at every quiet point (a sleep edge, before an ECUReset).
pub fn (mut m Memory) persist(now u64, flush bool) bool {
	m.wrote = 0
	if !m.stored() {
		return true
	}
	if !flush && now < m.retry_at {
		m.refused = m.refused || m.clear_refused // a 0x14 refused meanwhile reaches the owner now
		m.clear_refused = false
		return false
	}
	ready, mut refused := m.write_snapshots(0, false)
	hold := !ready
	mut deferred := false
	// 2. the image — not while a snapshot that DISPLACED a stored one is unwritten: that image
	// would drop the victim's claim with nothing in its place, and a power cut would leave neither
	// (the durable image still claims the victim, whose block is untouched). Another refused
	// snapshot holds nothing back: the image simply does not claim it yet.
	n := m.image(false, 0)
	changed, only_occ := m.image_change(n)
	if hold {
		refused = true
	} else if changed && (flush || !only_occ) {
		if m.store.put(m.store.ctx, m.store.id, &m.scratch[0], u16(n)) {
			m.commit_image(n)
			m.wrote++
		} else {
			refused = true
		}
	} else if changed {
		deferred = true // only occurrence counters: durable with the next image write or flush
	}
	// 3. tombstones: a block the committed image does not claim and no captured snapshot waits in
	for i in 0 .. m.n {
		for b in u8(1) .. 3 {
			if !m.slots[i].live[b - 1] || m.slots[i].claim == b
				|| (m.slots[i].entry != 0 && m.entries[m.slots[i].entry - 1].blk == b) {
				continue
			}
			m.scratch[0] = 0
			if m.store.put(m.store.ctx, m.block_id(i, b), &m.scratch[0], 1) {
				m.slots[i].live[b - 1] = false
				m.wrote++
			} else {
				refused = true
			}
		}
	}
	m.retry_at = if refused { now + m.store.retry_us } else { u64(0) }
	// a refusal since the last persist — this one's, or a 0x14's — stays visible to the owner,
	// which may make room (a node without NM erases then)
	m.refused = refused || m.clear_refused
	m.clear_refused = false
	return !refused && !deferred
}

// write_snapshots writes every captured snapshot not yet in the store — before any image that
// claims it — skipping those of the DTCs a clear of `group` is about to free (`clearing`); it
// returns (every snapshot that displaced a stored one is in — else the image must wait for it,
// any write was refused).
fn (mut m Memory) write_snapshots(group u32, clearing bool) (bool, bool) {
	mut ok := true
	mut refused := false
	for k in 0 .. m.cap {
		if !m.entries[k].used || m.entries[k].durable {
			continue
		}
		i := m.entries[k].slot
		if clearing && (group == 0xFFFFFF || m.slots[i].dtc == group) {
			continue
		}
		n := m.snapshot_block(k)
		b := m.entries[k].blk
		if m.store.put(m.store.ctx, m.block_id(i, b), &m.scratch[0], u16(n)) {
			m.entries[k].durable = true
			m.slots[i].live[b - 1] = true
			m.wrote++
		} else {
			refused = true
			if m.entries[k].took_claim {
				ok = false
			}
		}
	}
	return ok, refused
}

// snapshot_block builds entry k's block into m.scratch and returns its length.
fn (mut m Memory) snapshot_block(k int) int {
	e := &m.entries[k]
	dtc := m.slots[e.slot].dtc
	m.scratch[0] = u8(dtc >> 16)
	m.scratch[1] = u8(dtc >> 8)
	m.scratch[2] = u8(dtc)
	m.scratch[3] = u8(e.stamp >> 24)
	m.scratch[4] = u8(e.stamp >> 16)
	m.scratch[5] = u8(e.stamp >> 8)
	m.scratch[6] = u8(e.stamp)
	fp := m.schema_fp(e.slot)
	m.scratch[7] = u8(fp >> 8)
	m.scratch[8] = u8(fp)
	for b in 0 .. e.len {
		m.scratch[snap_hdr + b] = e.data[b]
	}
	return snap_hdr + e.len
}

// persist_clear: 0x14's image made durable before the clear touches RAM (true without a store).
fn (mut m Memory) persist_clear(group u32) bool {
	m.wrote = 0
	if !m.stored() {
		return true
	}
	// the snapshots first, for the reason persist writes them first
	ready, _ := m.write_snapshots(group, true)
	if !ready {
		m.clear_refused = true
		return false
	}
	n := m.image(true, group)
	if !m.store.put(m.store.ctx, m.store.id, &m.scratch[0], u16(n)) {
		m.clear_refused = true
		return false
	}
	m.commit_image(n)
	m.wrote++
	return true
}

// restore reads the store back, after init (slots configured) and before the first report is
// consumed: each DTC's persisted bits and counters by its DTC NUMBER (a firmware update may have
// reordered, added or removed faults), the snapshots the image claims, and the interrupted
// operation cycle, which it ends. A DTC the image does not know starts as after a clear.
pub fn (mut m Memory) restore() {
	if !m.stored() {
		return
	}
	// two distinct, real snapshot blocks per DTC, or no snapshot: block id 0 is the journal's
	// clean marker, and a single block for A and B would be overwritten under its own claim
	for i in 0 .. m.n {
		s := &m.slots[i]
		if s.nfreeze > 0 && (s.snap_id == 0 || s.snap_id_b == 0 || s.snap_id == s.snap_id_b) {
			m.slots[i].nfreeze = 0
		}
	}
	n := int(m.store.get(m.store.ctx, m.store.id, &m.img[0], u16(max_image)))
	m.img_len = 0
	mut open := false
	mut off := false
	if n >= 2 && m.img[0] == image_version && (n - 2) % image_rec == 0 {
		m.img_len = n
		open = m.img[1] & img_cycle_open != 0
		off = m.img[1] & img_setting_off != 0
		for r in 0 .. (n - 2) / image_rec {
			o := 2 + r * image_rec
			dtc := u32(m.img[o]) << 16 | u32(m.img[o + 1]) << 8 | u32(m.img[o + 2])
			i := m.slot_of(dtc)
			if i < 0 {
				continue
			}
			f := m.img[o + 3]
			mut s := &m.slots[i]
			s.status = (f & persisted_bits) | not_completed_this_cycle
			s.tested_cycle = f & img_tested != 0
			s.failed_cycle = f & img_failed != 0
			s.failed_cycles = m.img[o + 4]
			s.aging_count = m.img[o + 5]
			s.occurrence = u16(m.img[o + 6]) << 8 | u16(m.img[o + 7])
			// the committed claim stands whether or not its block is readable: what it claims is
			// released only by a committed image that no longer claims it
			s.claim = if s.nfreeze > 0 { claim_of(f) } else { u8(0) }
			s.claim_ok = s.claim != 0 && m.load_snapshot(i, s.claim)
		}
		m.fit_entries()
	}
	for i in 0 .. m.n {
		mut s := &m.slots[i]
		if s.nfreeze == 0 {
			continue
		}
		// a block nothing claims is tombstoned at the next persist (the one just loaded is live)
		for b in u8(1) .. 3 {
			s.live[b - 1] = (s.entry != 0 && m.entries[s.entry - 1].blk == b)
				|| int(m.store.get(m.store.ctx, m.block_id(i, b), &m.scratch[0], 2)) > 1
		}
	}
	if open {
		// the cycle power interrupted ends with what it saw — under the DTC setting it ended
		// under: with 0x85 off its end changes nothing, as it would have changed nothing then.
		// Setting is on again: a power-up ends every session.
		m.cycle_active = true
		m.setting_off = off
		m.cycle_end()
		m.setting_off = false
	}
}

// schema_fp: slot i's snapshot schema — its DIDs and their sizes — folded to 16 bits (FNV-1a),
// stored in every snapshot block so a snapshot of another schema is never restored as this one.
fn (m &Memory) schema_fp(i int) u16 {
	mut h := u32(0x811C9DC5)
	for f in 0 .. m.slots[i].nfreeze {
		h = fnv(h, u8(m.slots[i].freeze[f] >> 8))
		h = fnv(h, u8(m.slots[i].freeze[f]))
		h = fnv(h, m.slots[i].freeze_len[f])
	}
	return u16(h ^ (h >> 16))
}

fn fnv(h u32, b u8) u32 {
	return (h ^ u32(b)) * 16777619
}

// load_snapshot reads slot i's snapshot block into a free entry; false = absent, malformed, or
// another DTC's.
fn (mut m Memory) load_snapshot(i int, b u8) bool {
	want := snap_hdr + m.snap_len(i)
	n := int(m.store.get(m.store.ctx, m.block_id(i, b), &m.scratch[0], u16(max_block)))
	if n != want {
		return false
	}
	dtc := u32(m.scratch[0]) << 16 | u32(m.scratch[1]) << 8 | u32(m.scratch[2])
	if dtc != m.slots[i].dtc || int(m.scratch[snap_hdr]) != m.slots[i].nfreeze
		|| u16(m.scratch[7]) << 8 | u16(m.scratch[8]) != m.schema_fp(i) {
		return false // another DTC's, or its snapshot under another schema (a kept snapshot_id)
	}
	// and the record's DIDs at the offsets this build's sizes put them — a second guard behind the
	// 16-bit fingerprint, against the one schema in 65536 that shares it
	mut o := snap_hdr + 1
	for f in 0 .. m.slots[i].nfreeze {
		if u16(m.scratch[o]) << 8 | u16(m.scratch[o + 1]) != m.slots[i].freeze[f] {
			return false
		}
		o += 2 + int(m.slots[i].freeze_len[f])
	}
	mut k := -1
	for j in 0 .. max_entries {
		if !m.entries[j].used {
			k = j
			break
		}
	}
	if k < 0 {
		return false
	}
	mut e := &m.entries[k]
	e.used = true
	e.slot = i
	e.durable = true
	e.blk = b
	e.took_claim = false
	e.stamp = u32(m.scratch[3]) << 24 | u32(m.scratch[4]) << 16 | u32(m.scratch[5]) << 8 | u32(m.scratch[6])
	e.len = n - snap_hdr
	for x in 0 .. e.len {
		e.data[x] = m.scratch[snap_hdr + x]
	}
	m.slots[i].entry = k + 1
	if e.stamp >= m.next_stamp {
		m.next_stamp = e.stamp + 1
	}
	return true
}

// fit_entries: restored snapshots past `cap` (an update that lowered it) are dropped — the least
// important, then the oldest — and the survivors are packed into entries 0 .. cap-1.
fn (mut m Memory) fit_entries() {
	for {
		mut used := 0
		for k in 0 .. max_entries {
			if m.entries[k].used {
				used++
			}
		}
		if used <= m.cap {
			break
		}
		mut worst := -1
		for k in 0 .. max_entries {
			if !m.entries[k].used {
				continue
			}
			if worst < 0 || m.drops_before(k, worst) {
				worst = k
			}
		}
		m.free_entry(m.entries[worst].slot) // its block stays claimed until an image that drops it commits
	}
	mut to := 0
	for k in 0 .. max_entries {
		if !m.entries[k].used {
			continue
		}
		if k != to {
			m.entries[to] = m.entries[k]
			m.entries[k].used = false
			m.slots[m.entries[to].slot].entry = to + 1
		}
		to++
	}
}

// drops_before: at restore, entry a is dropped before b — less important, then older.
fn (m &Memory) drops_before(a int, b int) bool {
	pa := prio(m.slots[m.entries[a].slot].priority)
	pb := prio(m.slots[m.entries[b].slot].priority)
	if pa != pb {
		return pa > pb
	}
	return m.entries[a].stamp < m.entries[b].stamp
}

// slot_of: the slot configured with `dtc`, -1 = none.
fn (m &Memory) slot_of(dtc u32) int {
	for i in 0 .. m.n {
		if m.slots[i].dtc == dtc {
			return i
		}
	}
	return -1
}

// block_id: slot i's snapshot block b (1 A, 2 B).
fn (m &Memory) block_id(i int, b u8) u16 {
	return if b == 2 { m.slots[i].snap_id_b } else { m.slots[i].snap_id }
}

// claim_of: the block an image's per-DTC flag byte claims — 0 none, 1 A, 2 B.
fn claim_of(f u8) u8 {
	if f & img_snapshot == 0 {
		return 0
	}
	return if f & img_block_b != 0 { u8(2) } else { u8(1) }
}
