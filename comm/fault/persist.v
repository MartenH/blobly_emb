module fault

// Persistence of the fault memory (docs/diagnostics.md §3.3, R6b): what survives a reset and a
// power loss, kept in an injected Store — the NvM journal on a ThreadX target (nvm.Journal through
// the generated seam), nothing on the host. Two kinds of value:
//
//   the STATUS IMAGE, one value under one fixed block id: every DTC's persisted status bits, its
//   counters, the current operation cycle's per-DTC flags, and which DTC holds a stored snapshot.
//   ONE value, so a group clear, a displacement and a cycle boundary are each one atomic write;
//
//   one SNAPSHOT block per DTC that declares `freeze` (its id derived from the DTC and the
//   snapshot's schema): the DTC, its allocation stamp and the record body — or a 1-byte TOMBSTONE
//   once the snapshot is gone, so a freed snapshot stops occupying journal space.
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
// cleared, aging) — plus once at each cycle start and end, and at each tester clear. Changes in one
// owner pass coalesce into one write. A later occurrence in the same cycle changes only the
// occurrence counter, which is DEFERRED: written with the next image write or at the next flush (a
// sleep edge, an ECUReset), never on its own — so an intermittent fault costs no write per
// occurrence, and a power cut can lose the occurrences counted since that cycle's first failure,
// never more and never doubled. A snapshot block is written once per allocation (at most one per
// DTC per cycle: an entry that failed this cycle cannot be displaced) and tombstoned once when
// freed. A refused write is retried no sooner than `retry_us` later.

pub const image_version = u8(1)
pub const image_rec = 8 // bytes per DTC in the image
pub const max_image = 2 + max_faults * image_rec
pub const snap_hdr = 7 // a snapshot block: DTC (3), stamp (4), then the record body
pub const max_block = max_image // the larger of an image and a snapshot block (test_the_scratch_holds_either)

// the status bits the image keeps
pub const persisted_bits = pending | confirmed | not_completed_since_clear | failed_since_clear

// the image's per-DTC flag byte: the persisted bits in their own positions, and beside them
const img_tested = u8(0x01) // tested in the cycle in progress
const img_failed = u8(0x02) // failed in the cycle in progress
const img_snapshot = u8(0x40) // holds a stored snapshot
const img_cycle_open = u8(0x01) // image byte 1: an operation cycle was in progress

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
	m.scratch[1] = if m.cycle_active { img_cycle_open } else { u8(0) }
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
		m.slots[i].claim_durable = m.img[2 + i * image_rec + 3] & img_snapshot != 0
	}
}

// persist writes what changed: unwritten snapshots, then the image (deferred when only occurrence
// counters moved, unless `flush`), then the tombstones the durable image allows. Returns true when
// the store holds everything (deferred counters included). Without `flush` a refused write holds
// every write until `retry_us` has passed; a flush always tries. Call once per owner pass, and
// with flush at every quiet point (a sleep edge, before an ECUReset).
pub fn (mut m Memory) persist(now u64, flush bool) bool {
	m.wrote = 0
	if !m.stored() {
		return true
	}
	if !flush && now < m.retry_at {
		return false
	}
	mut refused := false
	mut deferred := false
	// 1. snapshots before the image that claims them
	for k in 0 .. m.cap {
		if !m.entries[k].used || m.entries[k].durable {
			continue
		}
		i := m.entries[k].slot
		n := m.snapshot_block(k)
		if m.store.put(m.store.ctx, m.slots[i].snap_id, &m.scratch[0], u16(n)) {
			m.entries[k].durable = true
			m.slots[i].blk_live = true
			m.wrote++
		} else {
			refused = true
		}
	}
	// 2. the image
	n := m.image(false, 0)
	changed, only_occ := m.image_change(n)
	if changed && (flush || !only_occ) {
		if m.store.put(m.store.ctx, m.store.id, &m.scratch[0], u16(n)) {
			m.commit_image(n)
			m.wrote++
		} else {
			refused = true
		}
	} else if changed {
		deferred = true // only occurrence counters: durable with the next image write or flush
	}
	// 3. tombstones, only for blocks the durable image no longer claims
	for i in 0 .. m.n {
		if !m.slots[i].blk_live || m.slots[i].entry != 0 || m.slots[i].claim_durable {
			continue
		}
		m.scratch[0] = 0
		if m.store.put(m.store.ctx, m.slots[i].snap_id, &m.scratch[0], 1) {
			m.slots[i].blk_live = false
			m.wrote++
		} else {
			refused = true
		}
	}
	if refused {
		m.retry_at = now + m.store.retry_us
	}
	return !refused && !deferred
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
	n := m.image(true, group)
	if !m.store.put(m.store.ctx, m.store.id, &m.scratch[0], u16(n)) {
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
	n := int(m.store.get(m.store.ctx, m.store.id, &m.img[0], u16(max_image)))
	m.img_len = 0
	mut open := false
	if n >= 2 && m.img[0] == image_version && (n - 2) % image_rec == 0 {
		m.img_len = n
		open = m.img[1] & img_cycle_open != 0
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
			s.claim_durable = f & img_snapshot != 0 && s.nfreeze > 0 && m.load_snapshot(i)
		}
		m.fit_entries()
	}
	for i in 0 .. m.n {
		mut s := &m.slots[i]
		if s.nfreeze == 0 {
			continue
		}
		// a block nothing claims is tombstoned at the next persist
		s.blk_live = s.entry != 0
			|| int(m.store.get(m.store.ctx, s.snap_id, &m.scratch[0], 2)) > 1
	}
	if open {
		m.cycle_active = true
		m.cycle_end() // the cycle power interrupted ends with what it saw
	}
}

// load_snapshot reads slot i's snapshot block into a free entry; false = absent, malformed, or
// another DTC's.
fn (mut m Memory) load_snapshot(i int) bool {
	want := snap_hdr + m.snap_len(i)
	n := int(m.store.get(m.store.ctx, m.slots[i].snap_id, &m.scratch[0], u16(max_block)))
	if n != want {
		return false
	}
	dtc := u32(m.scratch[0]) << 16 | u32(m.scratch[1]) << 8 | u32(m.scratch[2])
	if dtc != m.slots[i].dtc || int(m.scratch[snap_hdr]) != m.slots[i].nfreeze {
		return false
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
	e.stamp = u32(m.scratch[3]) << 24 | u32(m.scratch[4]) << 16 | u32(m.scratch[5]) << 8 | u32(m.scratch[6])
	e.len = n - snap_hdr
	for b in 0 .. e.len {
		e.data[b] = m.scratch[snap_hdr + b]
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
		i := m.entries[worst].slot
		m.free_entry(i)
		m.slots[i].claim_durable = false
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
