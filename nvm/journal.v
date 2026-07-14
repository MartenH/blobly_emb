module nvm

// The persistence journal engine (docs/nvm.md P1): an append journal over a
// flash sector pair, pure V over boot.FlashOps — the SAME hooks the bootloader
// defined, so RAM backs it in tests, a file in the host sim, and
// boards/<b>/flash.c on target. No-alloc, single-threaded by contract (ALL
// journal calls come from one thread — the comm thread on target).
//
// Record = one 32-byte unit. On flashes whose program word is 32 bytes (H7) a
// record is atomic by hardware; on smaller program units (AURIX DFLASH 8 B
// pages) it is safe by FORMAT: any missing unit fails the record CRC.
//
//   [0..1]  block_id u16 LE   0 = the clean-shutdown marker; 1..N = blocks
//   [2..3]  len      u16 LE   payload bytes (1..20; marker = 0)
//   [4..7]  seq      u32 LE   global monotonic counter — highest valid wins
//   [8..27] data     20 B
//   [28..31] crc32       LE   over bytes 0..27
//
// Invariants (the design's, HARDENED per the 2026-07-15 review round):
//   - append-only; no flash word is ever programmed twice — a FAILED program
//     burns its slot (the driver may have touched the word; re-programming a
//     touched ECC word is illegal);
//   - mount is READ-ONLY: scan + table + cursor. It never programs and never
//     erases; crash recovery belongs to erase_pending()/compact() at runtime;
//   - a power cut or transient driver failure at any point leaves the journal
//     mountable with "last complete value per block wins";
//   - compaction copies from the RAM table (the source of truth), never from
//     flash, and PRESERVES a clean tail (re-appends the marker);
//   - the live set must fit one sector — checked at mount and compact (the
//     generator's capacity gate makes these unreachable in a valid config;
//     the engine refuses rather than recursing).

import boot

pub const rec_size = u32(32)
pub const data_max = u32(20)
pub const marker_block = u16(0)
// RAM-table capacity: index = block_id (1..max_blocks-1). The generator sizes
// real use far below this; the constant only bounds the static table.
pub const max_blocks = 64

// refuse appends when seq approaches wrap — "highest wins" would invert. Not
// reachable through flash endurance (2^32 appends outlives any wear budget);
// the guard exists so the invariant is enforced, not assumed.
const seq_ceiling = u32(0xFFFF_FF00)

// Entry is the mounted latest-value of one block (the RAM table row).
pub struct Entry {
pub mut:
	present bool
	sector  int // which sector its NEWEST record lives in (stray bookkeeping)
	len     u16
	seq     u32
	data    [20]u8
}

pub struct SectorCfg {
pub mut:
	a_addr u32
	b_addr u32
	size   u32 // per sector, a multiple of rec_size
}

pub struct Journal {
pub mut:
	ops boot.FlashOps
	cfg SectorCfg
	// the mount table: the source of truth for latest values (compaction copies
	// from HERE, never from stale flash — writes during GC stay correct).
	table   [64]Entry
	max_seq u32
	active  int // 0 = sector A, 1 = B
	cursor  u32 // byte offset of the next append in the active sector
	// a sector holding outranked records / interrupted-erase dirt, awaiting
	// cleanup (erase — or a compact when strays live there) at a quiet point
	pending_erase int = -1
	// the non-active sector is KNOWN fully erased (compact may skip its erase)
	partner_clean bool
	// mount verdict: the previous session ended with the clean marker as the
	// newest record (slept orderly). Fresh/empty journal counts as clean.
	clean bool
	// runtime tail state: the newest appended record is the marker — compaction
	// re-appends the marker to keep a clean tail clean across the copy.
	tail_clean bool
	mounted    bool
	// reentry guard: compact()'s own copy appends must never re-compact
	compacting bool
}

fn (j Journal) sector_addr(s int) u32 {
	return if s == 0 { j.cfg.a_addr } else { j.cfg.b_addr }
}

fn (j Journal) slots() u32 {
	return j.cfg.size / rec_size
}

// mount scans both sectors (READ-ONLY), builds the table (union, highest seq
// wins), derives the active sector + cursor from content, and classifies the
// last session. Strays in the partner sector stay where they are — the table
// serves them; erase_pending() re-homes them (via compact) at a quiet point.
pub fn (mut j Journal) mount() bool {
	if j.cfg.size < rec_size || j.ops.read == unsafe { nil } || j.ops.program == unsafe { nil }
		|| j.ops.erase == unsafe { nil } {
		return false
	}
	for i in 0 .. max_blocks {
		j.table[i] = Entry{}
	}
	j.max_seq = 0
	j.pending_erase = -1
	mut newest_is_marker := true // empty journal = clean
	mut newest_seq := u32(0)
	mut any_valid := false
	mut nonempty := [2]bool{}
	mut dirty_tail := [2]bool{} // non-blank content beyond the append frontier
	mut clean_sector := [2]bool{init: true} // fully erased (whole-sector scan)
	mut trailing_invalid := [2]bool{} // the LAST non-blank word failed to parse
	mut cursors := [2]u32{}
	mut maxseq_in := [2]u32{}
	mut rec := [32]u8{}
	for s in 0 .. 2 {
		mut off := u32(0)
		mut past_end := false
		for off + rec_size <= j.cfg.size {
			addr := j.sector_addr(s) + off
			if j.slot_blank(addr, &rec[0]) {
				if !past_end {
					past_end = true
					cursors[s] = off
				}
				off += rec_size
				continue // keep scanning: an interrupted erase hides dirt later
			}
			clean_sector[s] = false
			if past_end {
				dirty_tail[s] = true // dirt beyond the frontier: no appends here
			}
			nonempty[s] = true
			off += rec_size
			if !past_end {
				cursors[s] = off
			}
			blk, len, seq, ok := parse_record(&rec[0])
			trailing_invalid[s] = !ok
			if !ok {
				continue // torn/corrupt: skip the word, lose nothing
			}
			any_valid = true
			if seq > j.max_seq {
				j.max_seq = seq
			}
			if seq > maxseq_in[s] {
				maxseq_in[s] = seq
			}
			if seq > newest_seq {
				newest_seq = seq
				newest_is_marker = blk == marker_block
			}
			if blk == marker_block || int(blk) >= max_blocks {
				continue
			}
			if seq > j.table[blk].seq || !j.table[blk].present {
				j.table[blk].present = true
				j.table[blk].sector = s
				j.table[blk].len = len
				j.table[blk].seq = seq
				for i in 0 .. int(len) {
					j.table[blk].data[i] = rec[8 + i]
				}
			}
		}
	}
	// active selection: freshest records win, but a dirty-tailed sector is
	// never appended into — prefer the clean-tailed one; if BOTH are dirty
	// (double-crash weather), declare the active full so the first append
	// compacts away from the dirt instead of programming into it.
	j.active = match true {
		nonempty[0] && nonempty[1] { if maxseq_in[1] > maxseq_in[0] { 1 } else { 0 } }
		nonempty[1] { 1 }
		else { 0 }
	}
	if dirty_tail[j.active] && !dirty_tail[1 - j.active] {
		j.active = 1 - j.active
	}
	// clean = "nothing happened after the marker", judged HONESTLY:
	//   - content but zero valid records (all torn/rotten) is NOT an orderly
	//     shutdown, whatever the scan default says;
	//   - a torn word at the ACTIVE sector's tail is a write ATTEMPT after the
	//     last valid record — if that record was the marker, the ECU woke and
	//     died mid-put: unclean, even though the torn write parses as nothing.
	//     (The old sector's tail is history, not post-marker activity.)
	if (nonempty[0] || nonempty[1]) && !any_valid {
		newest_is_marker = false
	}
	if trailing_invalid[j.active] {
		newest_is_marker = false
	}
	j.clean = newest_is_marker
	j.tail_clean = newest_is_marker
	j.cursor = if dirty_tail[j.active] { j.cfg.size } else { cursors[j.active] }
	other := 1 - j.active
	j.partner_clean = clean_sector[other]
	if !clean_sector[other] {
		j.pending_erase = other
	}
	// NOTE: mount never refuses on capacity — whatever is readable is served
	// (read-only). An over-capacity live set is caught where it would corrupt:
	// compact() refuses to run and put() fails once the sector is full.
	j.mounted = true
	return true
}

// put appends a new value. On failure the table is ROLLED BACK (a failed put
// must be neither served nor re-persisted by a later compaction) and the
// flash slot is burned — see program_slot.
pub fn (mut j Journal) put(block u16, data &u8, len u16) bool {
	if !j.mounted || block == marker_block || int(block) >= max_blocks {
		return false
	}
	if len == 0 || u32(len) > data_max {
		return false // empty would be indistinguishable from absent — reject
	}
	prev := j.table[block] // rollback copy (fixed-size struct, plain value)
	j.table[block].present = true
	j.table[block].len = len
	for i in 0 .. int(len) {
		j.table[block].data[i] = unsafe { data[i] }
	}
	if !j.append_block(block) {
		j.table[block] = prev
		return false
	}
	j.tail_clean = false
	return true
}

// get reads the mounted/current value into out; returns the length (0 = absent).
pub fn (j Journal) get(block u16, out &u8, cap u16) u16 {
	if !j.mounted || int(block) >= max_blocks || !j.table[block].present {
		return 0
	}
	mut n := j.table[block].len
	if n > cap {
		n = cap
	}
	for i in 0 .. int(n) {
		unsafe {
			out[i] = j.table[block].data[i]
		}
	}
	return n
}

// mark_clean appends the clean-shutdown marker — call it LAST in the shutdown
// flush. Clean iff the newest record is a marker; any later put makes the
// session "woke again". Compaction preserves a clean tail, so
// mark_clean -> compact -> power-off still mounts clean.
pub fn (mut j Journal) mark_clean() bool {
	if !j.mounted {
		return false
	}
	if !j.append_marker() {
		return false
	}
	j.tail_clean = true
	return true
}

// free_records: append slots left in the active sector — the caller's
// watermark input (reserve = live blocks + 1 marker, checked at generation).
pub fn (j Journal) free_records() u32 {
	return (j.cfg.size - j.cursor) / rec_size
}

// live_records: current live set size (+1 for the marker) — the reserve the
// shutdown flush needs, and the compaction footprint.
pub fn (j Journal) live_records() u32 {
	mut n := u32(1)
	for b in 1 .. max_blocks {
		if j.table[b].present {
			n++
		}
	}
	return n
}

// strays: live blocks whose newest record sits in the given sector — data an
// erase of that sector would orphan.
pub fn (j Journal) strays(sector int) u32 {
	mut n := u32(0)
	for b in 1 .. max_blocks {
		if j.table[b].present && j.table[b].sector == sector {
			n++
		}
	}
	return n
}

// compact copies the live set FROM THE TABLE into the partner sector (fresh
// seqs — copies outrank originals; interleaved puts stay correct because the
// table is the source), re-appends the marker if the tail was clean, switches
// active, and leaves the old sector for erase_pending(). Failure-ordered: on
// a mid-copy failure the journal REVERTS to the old sector (intact, full) and
// the half-written target is scheduled for erase — a retry erases it and
// starts over; no word is ever programmed twice.
pub fn (mut j Journal) compact() bool {
	if !j.mounted || j.compacting {
		return false
	}
	if j.live_records() > j.slots() {
		return false // cannot converge; refuse rather than recurse
	}
	target := 1 - j.active
	if !j.partner_clean {
		// safe even when the target holds an interrupted compaction's source:
		// the TABLE already unions everything, nothing is lost.
		if !j.ops.erase(j.ops.ctx, j.sector_addr(target), j.cfg.size) {
			return false
		}
	}
	old_active := j.active
	old_cursor := j.cursor
	was_clean := j.tail_clean
	j.compacting = true
	j.active = target
	j.cursor = 0
	j.partner_clean = false // the target is being written; the old side is full
	mut ok := true
	for b in 1 .. max_blocks {
		if j.table[b].present {
			if !j.append_block(u16(b)) {
				ok = false
				break
			}
		}
	}
	if ok && was_clean {
		ok = j.append_marker()
	}
	j.compacting = false
	if !ok {
		// revert to the (intact, full) old sector; re-point the table rows the
		// copy already re-homed; the half-written target needs an erase first.
		j.active = old_active
		j.cursor = old_cursor
		for b in 1 .. max_blocks {
			if j.table[b].present && j.table[b].sector == target {
				j.table[b].sector = old_active
			}
		}
		j.pending_erase = target
		j.partner_clean = false
		return false
	}
	j.pending_erase = old_active
	return true
}

// erase_pending performs the deferred cleanup at the caller's quiet point.
// If the pending sector still holds any block's NEWEST record (strays — a
// crash interrupted a compaction), erasing would orphan them: run a compact
// instead (it erases the pending target first and re-homes everything).
pub fn (mut j Journal) erase_pending() bool {
	if !j.mounted {
		return false
	}
	if j.pending_erase < 0 {
		return true
	}
	if j.pending_erase == j.active {
		return false // never erase the active sector (state-corruption guard)
	}
	if j.strays(j.pending_erase) > 0 {
		return j.compact() // re-homes strays; pending moves to the old active
	}
	if !j.ops.erase(j.ops.ctx, j.sector_addr(j.pending_erase), j.cfg.size) {
		return false
	}
	j.partner_clean = true
	j.pending_erase = -1
	return true
}

// --- internals -------------------------------------------------------------

// ensure_space: room for one record. Outside compaction a full sector triggers
// the inline compact; the post-condition is RE-CHECKED so a copy that fills
// the target can never program out of bounds.
fn (mut j Journal) ensure_space() bool {
	if j.max_seq >= seq_ceiling {
		return false // seq would wrap; the journal freezes rather than lie
	}
	if j.cursor + rec_size > j.cfg.size {
		if j.compacting {
			return false // a copy overflowing the target = capacity bug; refuse
		}
		if !j.compact() {
			return false
		}
		if j.cursor + rec_size > j.cfg.size {
			return false
		}
	}
	return true
}

fn (mut j Journal) append_block(block u16) bool {
	if !j.ensure_space() {
		return false
	}
	// seq is allocated AFTER space exists: an inline compact bumps seqs, and a
	// pre-allocated one would land out of order (the outranked-marker bug).
	mut rec := [32]u8{}
	seq := j.max_seq + 1
	encode_record(mut rec, block, j.table[block].len, seq, &j.table[block].data[0])
	if !j.program_slot(&rec[0]) {
		return false
	}
	j.max_seq = seq
	j.table[block].seq = seq
	j.table[block].sector = j.active
	return true
}

fn (mut j Journal) append_marker() bool {
	if !j.ensure_space() {
		return false
	}
	mut rec := [32]u8{}
	seq := j.max_seq + 1
	encode_record(mut rec, marker_block, 0, seq, unsafe { nil })
	if !j.program_slot(&rec[0]) {
		return false
	}
	j.max_seq = seq
	return true
}

// program_slot: one record at the cursor. The slot is consumed WHETHER OR NOT
// the program succeeds — a failing driver may still have touched the word,
// and re-programming a touched ECC word is illegal (H7 PGSERR / ECC garbage).
// A burned slot reads as a torn record at the next mount and is skipped.
fn (mut j Journal) program_slot(rec &u8) bool {
	addr := j.sector_addr(j.active) + j.cursor
	j.cursor += rec_size
	return j.ops.program(j.ops.ctx, addr, rec, rec_size)
}

// slot_blank: is the record slot at addr erased? The driver blank-check is
// preferred (DFLASH has no readable erased pattern; on ECC parts it classifies
// a torn-but-reads-blank word as NOT blank, keeping the frontier off it).
// Non-blank slots are read into rec for the caller's parse — if the read
// itself fails (ECC fault on a torn word), the slot counts as non-blank dirt
// and the CRC rejects whatever landed in rec.
fn (mut j Journal) slot_blank(addr u32, rec &u8) bool {
	if j.ops.blank != unsafe { nil } {
		if j.ops.blank(j.ops.ctx, addr, rec_size) {
			return true
		}
		j.read_slot(addr, rec) // best effort; garbage is CRC-rejected
		return false
	}
	if !j.read_slot(addr, rec) {
		return false // unreadable = not blank; treated as dirt
	}
	for i in 0 .. int(rec_size) {
		if unsafe { rec[i] } != 0xFF {
			return false
		}
	}
	return true
}

fn (mut j Journal) read_slot(addr u32, rec &u8) bool {
	return j.ops.read(j.ops.ctx, addr, rec, rec_size)
}

fn encode_record(mut rec [32]u8, block u16, len u16, seq u32, data &u8) {
	for i in 0 .. 32 {
		rec[i] = 0
	}
	rec[0] = u8(block)
	rec[1] = u8(block >> 8)
	rec[2] = u8(len)
	rec[3] = u8(len >> 8)
	rec[4] = u8(seq)
	rec[5] = u8(seq >> 8)
	rec[6] = u8(seq >> 16)
	rec[7] = u8(seq >> 24)
	for i in 0 .. int(len) {
		rec[8 + i] = unsafe { data[i] }
	}
	crc := boot.crc32(&rec[0], 28)
	rec[28] = u8(crc)
	rec[29] = u8(crc >> 8)
	rec[30] = u8(crc >> 16)
	rec[31] = u8(crc >> 24)
}

fn parse_record(p &u8) (u16, u16, u32, bool) {
	blk := unsafe { u16(p[0]) | (u16(p[1]) << 8) }
	len := unsafe { u16(p[2]) | (u16(p[3]) << 8) }
	seq := unsafe { u32(p[4]) | (u32(p[5]) << 8) | (u32(p[6]) << 16) | (u32(p[7]) << 24) }
	crc := unsafe { u32(p[28]) | (u32(p[29]) << 8) | (u32(p[30]) << 16) | (u32(p[31]) << 24) }
	if u32(len) > data_max {
		return 0, 0, 0, false
	}
	if boot.crc32(p, 28) != crc {
		return 0, 0, 0, false
	}
	return blk, len, seq, true
}
