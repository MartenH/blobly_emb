module nvm

// The persistence journal engine (docs/nvm.md P1): an append journal over a
// flash sector pair, pure V over boot.FlashOps — the SAME hooks the bootloader
// defined, so RAM backs it in tests, a file in the host sim, and
// boards/<b>/flash.c on target. No-alloc, single-threaded by contract (ALL
// journal calls come from one thread — the comm thread on target).
//
// Record = one 32-byte flash word (the H7 program granularity — atomic by
// construction):
//
//   [0..1]  block_id u16 LE   0 = the clean-shutdown marker; 1..N = blocks
//   [2..3]  len      u16 LE   payload bytes (<= 20)
//   [4..7]  seq      u32 LE   global monotonic counter — highest valid wins
//   [8..27] data     20 B
//   [28..31] crc32       LE   over bytes 0..27
//
// Invariants (the design's, enforced here):
//   - append-only: old records are never touched; a torn append fails its CRC
//     and the previous record for that block wins (power-loss safety from the
//     format);
//   - mount unions BOTH sectors, highest seq per block wins; a crash anywhere
//     in compaction converges (mount completes an interrupted copy itself);
//   - the erase is split out (erase_pending) so the caller runs it at a quiet
//     point — mount never erases;
//   - writes are legal at any moment there is cursor space; free_records() +
//     the caller's watermark keep that true by policy.

import boot

pub const rec_size = u32(32)
pub const data_max = u32(20)
pub const marker_block = u16(0)
// RAM-table capacity: index = block_id (1..max_blocks-1). The generator sizes
// real use far below this; the constant only bounds the static table.
pub const max_blocks = 64

const erased_word = u32(0xFFFF_FFFF)

// Entry is the mounted latest-value of one block (the RAM table row).
pub struct Entry {
pub mut:
	present bool
	sector  int // which sector its NEWEST record lives in (mount bookkeeping)
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
	// a full, everywhere-outranked sector awaiting its erase at a quiet point
	pending_erase int = -1
	// the non-active sector is KNOWN fully erased (compact may skip its erase).
	// Derived at mount by a full scan — an INTERRUPTED erase leaves a sector
	// that looks empty at its head but carries garbage later; appending into it
	// would program over dirt, so cleanliness is a whole-sector fact.
	partner_clean bool
	// mount verdict: the previous session ended with the clean marker as the
	// newest record (slept orderly). Fresh/empty journal counts as clean.
	clean bool
}

fn (j Journal) sector_addr(s int) u32 {
	return if s == 0 { j.cfg.a_addr } else { j.cfg.b_addr }
}

// mount scans both sectors, builds the table (union, highest seq wins),
// derives the active sector + cursor, completes an interrupted compaction
// (copy only — the erase stays pending), and classifies the last session.
pub fn (mut j Journal) mount() bool {
	for i in 0 .. max_blocks {
		j.table[i] = Entry{}
	}
	j.max_seq = 0
	j.pending_erase = -1
	mut newest_is_marker := true // empty journal = clean
	mut newest_seq := u32(0)
	mut nonempty := [false, false]
	mut clean_sector := [true, true] // fully erased (whole-sector scan)
	mut cursors := [u32(0), u32(0)]
	mut maxseq_in := [u32(0), u32(0)]
	mut rec := [32]u8{}
	for s in 0 .. 2 {
		mut off := u32(0)
		mut past_end := false // saw the first erased word; anything after = dirt
		for off + rec_size <= j.cfg.size {
			if !j.ops.read(j.ops.ctx, j.sector_addr(s) + off, &rec[0], rec_size) {
				return false
			}
			if j.word_blank(j.sector_addr(s) + off, &rec[0]) {
				if !past_end {
					past_end = true
					cursors[s] = off
				}
				off += rec_size
				continue // keep scanning: an interrupted erase hides dirt later
			}
			clean_sector[s] = false
			if past_end {
				// dirt beyond the append frontier (interrupted erase) — the
				// sector is unusable until erased; its records still count
				// toward the union below, nothing is lost.
			}
			nonempty[s] = true
			off += rec_size
			if !past_end {
				cursors[s] = off
			}
			blk, len, seq, ok := parse_record(&rec[0])
			if !ok {
				continue // torn/corrupt: skip the word, lose nothing
			}
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
	j.clean = newest_is_marker
	// derive the active sector: the one holding the freshest records; a lone
	// non-empty sector is active by default; empty journal starts in A.
	j.active = match true {
		nonempty[0] && nonempty[1] { if maxseq_in[1] > maxseq_in[0] { 1 } else { 0 } }
		nonempty[1] { 1 }
		else { 0 }
	}
	j.cursor = cursors[j.active]
	other := 1 - j.active
	j.partner_clean = clean_sector[other]
	if !clean_sector[other] {
		// the partner holds SOMETHING (an interrupted compaction's source, or
		// an interrupted erase's dirt). Re-home any value whose newest record
		// lives there (µs-scale appends — mount never erases), then leave the
		// sector for the caller's quiet point.
		for b in 1 .. max_blocks {
			if j.table[b].present && j.table[b].sector == other {
				if !j.append_block(u16(b)) {
					return false
				}
			}
		}
		j.pending_erase = other
	}
	return true
}

// put stages nothing — it IS the append (the caller owns rate policy). Updates
// the table first so compaction always copies the freshest value.
pub fn (mut j Journal) put(block u16, data &u8, len u16) bool {
	if block == marker_block || int(block) >= max_blocks || u32(len) > data_max {
		return false
	}
	j.table[block].present = true
	j.table[block].len = len
	for i in 0 .. int(len) {
		j.table[block].data[i] = unsafe { data[i] }
	}
	return j.append_block(block)
}

// get reads the mounted/current value into out; returns the length (0 = absent).
pub fn (j Journal) get(block u16, out &u8, cap u16) u16 {
	if int(block) >= max_blocks || !j.table[block].present {
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
// session "woke again" (unclean-by-tail), exactly as designed.
pub fn (mut j Journal) mark_clean() bool {
	mut rec := [32]u8{}
	j.max_seq++
	encode_record(mut rec, marker_block, 0, j.max_seq, unsafe { nil })
	return j.append_raw(&rec[0])
}

// free_records: append slots left in the active sector — the caller's
// watermark input (reserve = live blocks + 1 marker, checked at generation).
pub fn (j Journal) free_records() u32 {
	return (j.cfg.size - j.cursor) / rec_size
}

// live_records: current live set size (+1 for the marker) — the reserve the
// shutdown flush needs.
pub fn (j Journal) live_records() u32 {
	mut n := u32(1)
	for b in 1 .. max_blocks {
		if j.table[b].present {
			n++
		}
	}
	return n
}

// compact copies the live set FROM THE TABLE into the partner sector (bumped
// seqs — copies outrank originals; interleaved puts stay correct because the
// table is the source), switches active, and leaves the old sector for
// erase_pending(). The partner is erased first if a previous erase is still
// pending (the caller's watermark policy makes that rare).
pub fn (mut j Journal) compact() bool {
	target := 1 - j.active
	if !j.partner_clean {
		// safe even when the target still holds an interrupted compaction's
		// source: the TABLE already unions everything, nothing is lost.
		if !j.ops.erase(j.ops.ctx, j.sector_addr(target), j.cfg.size) {
			return false
		}
	}
	old := j.active
	j.active = target
	j.cursor = 0
	for b in 1 .. max_blocks {
		if j.table[b].present {
			if !j.append_block(u16(b)) {
				return false
			}
		}
	}
	j.pending_erase = old
	j.partner_clean = false
	return true
}

// erase_pending performs the deferred erase — the caller runs it at a quiet
// point (sleep entry; or anytime on boards where the journal bank is not
// executed from).
pub fn (mut j Journal) erase_pending() bool {
	if j.pending_erase < 0 {
		return true
	}
	if !j.ops.erase(j.ops.ctx, j.sector_addr(j.pending_erase), j.cfg.size) {
		return false
	}
	if j.pending_erase == 1 - j.active {
		j.partner_clean = true
	}
	j.pending_erase = -1
	return true
}

// --- internals -------------------------------------------------------------

fn (mut j Journal) append_block(block u16) bool {
	mut rec := [32]u8{}
	j.max_seq++
	encode_record(mut rec, block, j.table[block].len, j.max_seq, &j.table[block].data[0])
	if !j.append_raw(&rec[0]) {
		return false
	}
	j.table[block].seq = j.max_seq
	j.table[block].sector = j.active
	return true
}

fn (mut j Journal) append_raw(rec &u8) bool {
	if j.cursor + rec_size > j.cfg.size {
		// engine-level correctness: compact inline when full. The runtime
		// watermark policy keeps this path off the shutdown flush.
		if !j.compact() {
			return false
		}
	}
	if !j.ops.program(j.ops.ctx, j.sector_addr(j.active) + j.cursor, rec, rec_size) {
		return false
	}
	j.cursor += rec_size
	return true
}

// word_blank: is this record slot erased? Prefers the driver's blank-check hook
// (mandatory on flashes where blankness is not a readable pattern — Infineon
// DFLASH); falls back to the all-0xFF test for ST/most-NOR erased state. The
// already-read bytes are passed so the fallback costs no extra read.
fn (j Journal) word_blank(addr u32, p &u8) bool {
	if j.ops.blank != unsafe { nil } {
		return j.ops.blank(j.ops.ctx, addr, rec_size)
	}
	for i in 0 .. int(rec_size) {
		if unsafe { p[i] } != 0xFF {
			return false
		}
	}
	return true
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
