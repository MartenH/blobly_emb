module nvm

// The persistence journal engine v2 (docs/nvm.md): an append journal over a
// flash sector pair, pure V over boot.FlashOps — the SAME hooks the bootloader
// defined, so RAM backs it in tests, a file in the host sim, and
// boards/<b>/flash.c on target. No-alloc, single-threaded by contract (ALL
// journal calls come from one thread — the comm thread on target).
//
// v2 over the fuzz-proven v1 (both landed 2026-07-15):
//   - KEYED TABLE: block ids are full-range u16 (schema-identity hashes from
//     the generator — insert/reorder/rename safe); the RAM table is a pool
//     scanned by id, not an index.
//   - CHAINED VALUES (ISO-TP-shaped): values > 20 B span contiguous parts
//     sharing ONE seq; part 0 carries the total length, the LAST part ends
//     with a CRC32 over the assembled value (completion evidence last). Mount
//     accepts the highest seq whose parts are all present, contiguous, and
//     whole-CRC-valid — a power cut mid-chain means the previous complete
//     value wins, the v1 rule one level up.
//
// Record = one 32-byte unit. On flashes whose program word is 32 bytes (H7) a
// record is atomic by hardware; on smaller program units (AURIX DFLASH 8 B
// pages) it is safe by FORMAT: any missing unit fails the record CRC.
//
//   [0..1]  block_id u16 LE   0 = the clean-shutdown marker; else a block id
//                             (full u16 range; 0xFFFF reserved = erased-like)
//   [2..3]  len      u16 LE   plain value: 1..20
//                             chained part: bit15 set | part_idx << 10 | plen
//   [4..7]  seq      u32 LE   global monotonic counter — highest valid wins
//   [8..27] data     20 B     (part 0: [total u16][data...]; last part ends
//                              with the whole-value CRC32)
//   [28..31] crc32       LE   over bytes 0..27 (per-record integrity)
//
// Invariants (v1's, all preserved):
//   - append-only; no flash word is ever programmed twice — a reported
//     program failure is READ-BACK-VERIFIED (landed intact = success), else
//     the slot is burned;
//   - mount is READ-ONLY: scan + table + cursor; recovery belongs to
//     erase_pending()/compact() at runtime; the append path NEVER erases;
//   - a power cut or transient driver failure at any point leaves the journal
//     mountable with "last complete value per block wins";
//   - compaction sources the RAM table for plain values and IMMUTABLE flash
//     for chain payloads (append-only flash cannot be stale), and PRESERVES a
//     clean tail; compact's table updates are DEFERRED so its failure revert
//     never leaves a chain reference pointing into a half-written sector;
//   - the live set (counted in RECORDS, parts included) must fit one sector.

import boot

pub const rec_size = u32(32)
pub const data_max = u32(20)
pub const marker_block = u16(0)
// chained-value ceiling: 32 parts x 20 B payload - 2 (total prefix) - 4 (CRC)
pub const chain_data_max = u16(634)
// RAM-table POOL capacity (not an id range — ids are full u16). The generator
// sizes real use far below this; the constant only bounds the static pool.
pub const max_blocks = 64

const id_reserved = u16(0xFFFF) // reads as erased-ish; never a block id

// chained len-field encoding
const chain_flag = u16(0x8000)
const part_shift = u16(10)
const plen_mask = u16(0x03FF)

// refuse appends when seq approaches wrap — "highest wins" would invert. Not
// reachable through flash endurance; enforced, not assumed.
const seq_ceiling = u32(0xFFFF_FF00)

// Entry is the mounted latest-value of one block (a RAM pool row). Plain
// values live inline in data[]; chained values are a REFERENCE into flash
// (append-only flash is immutable, so the reference is never stale).
pub struct Entry {
pub mut:
	present bool
	id      u16
	sector  int // which sector its NEWEST record(s) live in (stray bookkeeping)
	chained bool
	len     u16 // plain: value length; chained: total assembled length
	seq     u32
	ref_off u32 // chained: offset of part 0 within `sector`
	data    [20]u8 // plain values only
}

pub struct SectorCfg {
pub mut:
	a_addr u32
	b_addr u32
	size   u32 // per sector, a multiple of rec_size
}

// Journal is ~2.6 KB (the 64-entry table dominates). Receivers MUST be `&Journal`
// or `mut Journal` — a value receiver copies the whole struct onto the caller's
// stack, and on target the comm thread has 4 KB sitting at the bottom of DTCM:
// one nested pair of value-receiver calls walks the stack off the memory map
// (REQ-NVM-013, found on the H755 bench as a t=+10s HardFault with PC=0).
pub struct Journal {
pub mut:
	ops boot.FlashOps
	cfg SectorCfg
	// the mount pool: the source of truth for the latest value per id.
	table   [64]Entry
	max_seq u32
	active  int // 0 = sector A, 1 = B
	cursor  u32 // byte offset of the next append in the active sector
	// a sector holding outranked records / interrupted-erase dirt, awaiting
	// cleanup (erase — or re-homing first when strays live there)
	pending_erase int = -1
	// the non-active sector is KNOWN fully erased (compact may skip its erase)
	partner_clean bool
	// mount verdict: the previous session ended with the clean marker as the
	// newest record (slept orderly). Fresh/empty journal counts as clean.
	clean bool
	// runtime tail state: the newest appended record is the marker
	tail_clean bool
	mounted    bool
	// mount found MORE distinct ids on flash than the pool holds and had to
	// drop some (scan-order). Unreachable behind the generator's block-count
	// gate; latched so misconfiguration is DETECTABLE, never silent loss.
	pool_overflow bool
	// reentry guard: compact()'s own copy appends must never re-compact
	compacting bool
}

fn (j &Journal) sector_addr(s int) u32 {
	return if s == 0 { j.cfg.a_addr } else { j.cfg.b_addr }
}

// slots: the sector capacity in records — pub so generated code can verify
// the config's geometry claim against the REAL map at boot.
pub fn (j &Journal) slots() u32 {
	return j.cfg.size / rec_size
}

// chain_parts: records needed for a chained value of `total` data bytes
// (2-byte total prefix + data + 4-byte whole-CRC, 20 B per part).
fn chain_parts(total u16) u32 {
	return (u32(total) + 6 + (data_max - 1)) / data_max
}

// find: pool index of a block id, or -1.
fn (j &Journal) find(id u16) int {
	for i in 0 .. max_blocks {
		if j.table[i].present && j.table[i].id == id {
			return i
		}
	}
	return -1
}

// slot_for: existing pool row for id, or a free row (-1 = pool full).
fn (j &Journal) slot_for(id u16) int {
	mut free := -1
	for i in 0 .. max_blocks {
		if j.table[i].present {
			if j.table[i].id == id {
				return i
			}
		} else if free < 0 {
			free = i
		}
	}
	return free
}

// records_of: how many flash records this entry's newest value occupies.
fn (j &Journal) records_of(i int) u32 {
	if j.table[i].chained {
		return chain_parts(j.table[i].len)
	}
	return 1
}

// --- mount -------------------------------------------------------------------

// ChainScan is mount's in-flight chain-run validator: parts must be
// contiguous, in order, same id + seq; the whole-value CRC accumulates
// incrementally (no assembly buffer) and must match the stored trailer.
struct ChainScan {
mut:
	active   bool
	id       u16
	seq      u32
	next     u32 // expected part index
	start    u32 // offset of part 0
	total    u16
	expected u32 // part count derived from total
	seen     u32 // data bytes accumulated
	crc      u32 // incremental CRC over the assembled data
	tail     [4]u8 // the stored whole-CRC (last 4 payload bytes of the last part)
}

// mount scans both sectors (READ-ONLY), builds the pool (union, highest seq
// wins — plain records and complete chains alike), derives the active sector
// + cursor from content, and classifies the last session.
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
	j.pool_overflow = false
	mut newest_is_marker := true // empty journal = clean
	mut newest_seq := u32(0)
	mut any_valid := false
	mut nonempty := [2]bool{}
	mut dirty_tail := [2]bool{}
	mut clean_sector := [2]bool{init: true}
	mut trailing_invalid := [2]bool{}
	mut cursors := [2]u32{}
	mut maxseq_in := [2]u32{}
	mut rec := [32]u8{}
	for s in 0 .. 2 {
		mut off := u32(0)
		mut past_end := false
		mut cs := ChainScan{}
		for off + rec_size <= j.cfg.size {
			addr := j.sector_addr(s) + off
			if j.slot_blank(addr, &rec[0]) {
				cs.active = false // the frontier breaks any run
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
			rec_off := off
			off += rec_size
			if !past_end {
				cursors[s] = off
			}
			blk, lenf, seq, ok := parse_record(&rec[0])
			trailing_invalid[s] = !ok
			if !ok {
				cs.active = false
				continue // torn/corrupt: skip the word, lose nothing
			}
			any_valid = true
			if seq > j.max_seq {
				j.max_seq = seq
			}
			// maxseq_in drives ACTIVE selection and must follow ADOPTED content:
			// an incomplete chain's parts (valid records, no value) must not
			// attract the cursor to a half-written compaction target — bumped
			// for plain records/markers here, for chains only on completion.
			if lenf & chain_flag == 0 && seq > maxseq_in[s] {
				maxseq_in[s] = seq
			}
			if seq > newest_seq {
				newest_seq = seq
				// a REAL marker is always plain — a chain-flagged block-0 record
				// is a crafted/corrupt artifact and must not testify to a clean
				// shutdown (defense-in-depth; per-record CRC blocks bit flips)
				newest_is_marker = blk == marker_block && (lenf & chain_flag) == 0
			}
			if lenf & chain_flag != 0 {
				// a chain part: feed the run validator; a completed run is a
				// candidate value
				if j.chain_step(mut cs, blk, lenf, seq, rec_off, &rec[0]) {
					j.adopt_chain(cs, s)
					if cs.seq > maxseq_in[s] {
						maxseq_in[s] = cs.seq // completed chains count for selection
					}
					cs.active = false
				}
				continue
			}
			cs.active = false // a plain record breaks any run
			if blk == marker_block || blk == id_reserved {
				continue
			}
			i := j.slot_for(blk)
			if i < 0 {
				j.pool_overflow = true // detectable: generator gate was violated
				continue
			}
			if !j.table[i].present || seq > j.table[i].seq {
				j.table[i].present = true
				j.table[i].id = blk
				j.table[i].sector = s
				j.table[i].chained = false
				j.table[i].len = lenf
				j.table[i].seq = seq
				for k in 0 .. int(lenf) {
					j.table[i].data[k] = rec[8 + k]
				}
			}
		}
	}
	// active selection: freshest records win, but a dirty-tailed sector is
	// never appended into; both dirty = force the first append to compact away.
	j.active = match true {
		nonempty[0] && nonempty[1] { if maxseq_in[1] > maxseq_in[0] { 1 } else { 0 } }
		nonempty[1] { 1 }
		else { 0 }
	}
	if dirty_tail[j.active] && !dirty_tail[1 - j.active] {
		j.active = 1 - j.active
	}
	// clean = "nothing happened after the marker", judged honestly (v1 rules).
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
	j.mounted = true
	return true
}

// chain_step advances the run validator with one chained record; returns true
// when the run just COMPLETED (all parts, whole-CRC verified).
fn (mut j Journal) chain_step(mut cs ChainScan, blk u16, lenf u16, seq u32, off u32, rec &u8) bool {
	idx := u32((lenf >> part_shift) & 0x1F)
	plen := u32(lenf & plen_mask)
	if plen == 0 || plen > data_max || blk == marker_block || blk == id_reserved {
		cs.active = false
		return false
	}
	if idx == 0 {
		// first frame: total length prefix
		if plen < 3 {
			cs.active = false
			return false
		}
		total := unsafe { u16(rec[8]) | (u16(rec[9]) << 8) }
		if total <= u16(data_max) || total > chain_data_max {
			cs.active = false // chains exist only for > data_max values
			return false
		}
		cs.active = true
		cs.id = blk
		cs.seq = seq
		cs.next = 1
		cs.start = off
		cs.total = total
		cs.expected = chain_parts(total)
		cs.seen = 0
		cs.crc = u32(0xFFFF_FFFF)
	} else {
		if !cs.active || blk != cs.id || seq != cs.seq || idx != cs.next
			|| off != cs.start + idx * rec_size {
			cs.active = false
			return false
		}
		cs.next = idx + 1
	}
	// accumulate the data bytes of this part (skip the 2-byte total prefix in
	// part 0; the final 4 payload bytes of the LAST part are the stored CRC)
	prefix := if idx == 0 { u32(2) } else { u32(0) }
	mut avail := plen - prefix
	remaining := u32(cs.total) - cs.seen
	is_last := idx == cs.expected - 1
	if is_last {
		if avail < 4 || avail - 4 != remaining {
			cs.active = false
			return false
		}
		avail -= 4
	} else if avail > remaining {
		cs.active = false
		return false
	}
	if avail > 0 {
		cs.crc = boot.crc32_update(cs.crc, unsafe { &u8(&rec[8 + prefix]) }, avail)
		cs.seen += avail
	}
	if !is_last {
		return false
	}
	// completion: compare the stored whole-CRC (immediately after the data)
	for k in 0 .. 4 {
		cs.tail[k] = unsafe { rec[8 + prefix + avail + u32(k)] }
	}
	stored := u32(cs.tail[0]) | (u32(cs.tail[1]) << 8) | (u32(cs.tail[2]) << 16) | (u32(cs.tail[3]) << 24)
	if (cs.crc ^ 0xFFFF_FFFF) != stored || cs.seen != u32(cs.total) {
		cs.active = false
		return false
	}
	return true
}

// adopt_chain installs a completed run as the block's value if it is newer.
fn (mut j Journal) adopt_chain(cs ChainScan, s int) {
	i := j.slot_for(cs.id)
	if i < 0 {
		j.pool_overflow = true // detectable: generator gate was violated
		return
	}
	if !j.table[i].present || cs.seq > j.table[i].seq {
		j.table[i].present = true
		j.table[i].id = cs.id
		j.table[i].sector = s
		j.table[i].chained = true
		j.table[i].len = cs.total
		j.table[i].seq = cs.seq
		j.table[i].ref_off = cs.start
	}
}

// --- the public API ------------------------------------------------------------

// put appends a new value (plain <= 20 B, chained <= chain_data_max). The pool
// is updated ONLY after the full flash append succeeds; the write ATTEMPT
// dirties the tail regardless of outcome. put() == false means UNCONFIRMED
// only when read-back could not confirm a landed record.
pub fn (mut j Journal) put(block u16, data &u8, len u16) bool {
	if !j.mounted || block == marker_block || block == id_reserved {
		return false
	}
	if len == 0 || len > chain_data_max {
		return false
	}
	// the RESULTING live set (marker slot included via live_records) must fit
	// one sector WITH GLOBAL REWRITE HEADROOM: a rewrite appends new records
	// while the old value is still live, so after ANY write the LARGEST live
	// value must still fit in the post-compact free space — otherwise small
	// writes could quietly strand a big value (each passing a merely
	// per-block check). Refuse the write that would wedge any future, not
	// the future itself.
	new_rec := if u32(len) <= data_max { u32(1) } else { chain_parts(len) }
	mut old_rec := u32(0)
	ei := j.find(block)
	if ei >= 0 {
		old_rec = j.records_of(ei)
	}
	mut worst := new_rec
	for i in 0 .. max_blocks {
		if j.table[i].present && i != ei {
			r := j.records_of(i)
			if r > worst {
				worst = r
			}
		}
	}
	if j.live_records() - old_rec + new_rec + worst > j.slots() {
		return false
	}
	if u32(len) <= data_max {
		return j.append_plain(block, data, len)
	}
	return j.append_chain(block, data, len)
}

// dirty_tail_now: called by the append paths immediately before the first
// program attempt — a refusal that never touched flash must not un-clean an
// orderly tail (a later compact would honestly re-append the marker).
fn (mut j Journal) dirty_tail_now() {
	j.tail_clean = false
}

// get reads the mounted/current value into out; returns the copied length
// (0 = absent; truncated to cap).
pub fn (j &Journal) get(block u16, out &u8, cap u16) u16 {
	if !j.mounted {
		return 0
	}
	i := j.find(block)
	if i < 0 {
		return 0
	}
	mut n := j.table[i].len
	if n > cap {
		n = cap
	}
	if !j.table[i].chained {
		for k in 0 .. int(n) {
			unsafe {
				out[k] = j.table[i].data[k]
			}
		}
		return n
	}
	// chained: assemble from the immutable flash reference
	if !j.read_chain(i, out, n) {
		return 0
	}
	return n
}

// read_chain copies `n` assembled data bytes of chained entry i into out.
fn (j &Journal) read_chain(i int, out &u8, n u16) bool {
	base := j.sector_addr(j.table[i].sector) + j.table[i].ref_off
	nparts := chain_parts(j.table[i].len)
	mut rec := [32]u8{}
	mut copied := u32(0)
	for k in u32(0) .. nparts {
		if copied >= u32(n) {
			break
		}
		if !j.ops.read(j.ops.ctx, base + k * rec_size, &rec[0], rec_size) {
			return false
		}
		// re-validate: mount's verdict does not cover rot/ECC decay AFTER
		// mount — a chain read must never serve garbage silently
		blk, lenf2, seq2, ok := parse_record(&rec[0])
		if !ok || blk != j.table[i].id || seq2 != j.table[i].seq
			|| lenf2 & chain_flag == 0 || u32((lenf2 >> part_shift) & 0x1F) != k {
			return false
		}
		lenf := lenf2
		plen := u32(lenf & plen_mask)
		prefix := if k == 0 { u32(2) } else { u32(0) }
		mut avail := plen - prefix
		if k == nparts - 1 {
			avail -= 4 // the whole-CRC trailer
		}
		for b in u32(0) .. avail {
			if copied >= u32(n) {
				break
			}
			unsafe {
				out[copied] = rec[8 + prefix + b]
			}
			copied++
		}
	}
	return copied == u32(n)
}

// prune drops pool rows whose id is not in keep[0..n) — the generator calls
// this after mount with the CURRENT schema's id set, so ids persisted by
// older firmware stop occupying pool rows and their records die at the next
// compaction. Returns the number of rows dropped.
pub fn (mut j Journal) prune(keep &u16, n int) u32 {
	if !j.mounted {
		return 0
	}
	mut dropped := u32(0)
	for i in 0 .. max_blocks {
		if !j.table[i].present {
			continue
		}
		mut found := false
		for k in 0 .. n {
			if unsafe { keep[k] } == j.table[i].id {
				found = true
				break
			}
		}
		if !found {
			j.table[i] = Entry{}
			dropped++
		}
	}
	// if every CURRENT id is present in the pool, whatever mount dropped is
	// stale by definition — destroying it at compaction is the intent, so the
	// degraded mode lifts. A missing keep id may be among the dropped: latch.
	if j.pool_overflow {
		mut all_present := true
		for k in 0 .. n {
			if j.find(unsafe { keep[k] }) < 0 {
				all_present = false
				break
			}
		}
		if all_present {
			j.pool_overflow = false
		}
	}
	return dropped
}

// mark_clean appends the clean-shutdown marker — call it LAST in the shutdown
// flush. Compaction/re-homing preserve a clean tail.
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
// watermark input (reserve = live RECORDS + 1 marker, checked at generation).
pub fn (j &Journal) free_records() u32 {
	return (j.cfg.size - j.cursor) / rec_size
}

// live_records: current live set size in RECORDS (chain parts counted) + the
// marker's slot — the shutdown reserve and the compaction footprint.
pub fn (j &Journal) live_records() u32 {
	mut n := u32(1)
	for i in 0 .. max_blocks {
		if j.table[i].present {
			n += j.records_of(i)
		}
	}
	return n
}

// strays: RECORDS whose newest copy sits in the given sector — the slots a
// re-home needs before that sector's erase.
pub fn (j &Journal) strays(sector int) u32 {
	mut n := u32(0)
	for i in 0 .. max_blocks {
		if j.table[i].present && j.table[i].sector == sector {
			n += j.records_of(i)
		}
	}
	return n
}

// compact copies the live set into the partner sector (fresh seqs — copies
// outrank originals; plain values from the pool, chain payloads from
// immutable flash), re-appends the marker if the tail was clean, switches
// active, and leaves the old sector for erase_pending(). Pool updates are
// DEFERRED to the end: a mid-copy failure reverts to the intact old sector
// with every reference still pointing at it.
pub fn (mut j Journal) compact() bool {
	if !j.mounted || j.compacting {
		return false
	}
	if j.pool_overflow {
		return false // ids were dropped at mount: compacting would DESTROY them
	}
	if j.live_records() > j.slots() {
		return false // cannot converge; refuse rather than recurse
	}
	target := 1 - j.active
	if !j.partner_clean {
		// power-safety order: re-home anything whose newest copy lives in the
		// target BEFORE erasing it (the pool alone is not durability).
		if !j.rehome_strays(target) {
			return false
		}
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
	j.partner_clean = false
	mut new_off := [max_blocks]u32{}
	mut new_seq := [max_blocks]u32{}
	mut ok := true
	for i in 0 .. max_blocks {
		if j.table[i].present {
			off, seq, e_ok := j.emit_entry(i)
			if !e_ok {
				ok = false
				break
			}
			new_off[i] = off
			new_seq[i] = seq
		}
	}
	if ok && was_clean {
		ok = j.append_marker()
	}
	j.compacting = false
	if !ok {
		// revert: the pool was never touched — every entry still references
		// the intact old sector; the half-written target awaits its erase.
		j.active = old_active
		j.cursor = old_cursor
		j.pending_erase = target
		j.partner_clean = false
		return false
	}
	for i in 0 .. max_blocks {
		if j.table[i].present {
			j.table[i].sector = target
			j.table[i].seq = new_seq[i]
			if j.table[i].chained {
				j.table[i].ref_off = new_off[i]
			}
		}
	}
	j.pending_erase = old_active
	return true
}

// erase_pending performs the deferred cleanup at the caller's quiet point,
// re-homing strays into the active sector FIRST (power-safe order).
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
	if j.pool_overflow {
		return false // dropped ids still live ONLY in flash: never erase them
	}
	if !j.rehome_strays(j.pending_erase) {
		return false
	}
	if !j.ops.erase(j.ops.ctx, j.sector_addr(j.pending_erase), j.cfg.size) {
		return false
	}
	j.partner_clean = true
	j.pending_erase = -1
	return true
}

// rehome_strays: copy every entry whose newest records live in `from` into
// the ACTIVE sector (pool updated per entry — each copy is durable the moment
// it lands), then restore the clean marker if the tail was clean. Fit-checked
// so the appends can never trigger a compact themselves.
fn (mut j Journal) rehome_strays(from int) bool {
	if from == j.active {
		return false
	}
	ns := j.strays(from)
	if ns == 0 {
		// the newest clean MARKER may still live in the sector about to be
		// erased — re-anchor it (one slot) so orderly stays orderly.
		if j.tail_clean {
			if !j.append_marker() {
				return false
			}
		}
		return true
	}
	was_clean := j.tail_clean
	need := ns + if was_clean { u32(1) } else { u32(0) }
	if j.free_records() < need {
		return false
	}
	for i in 0 .. max_blocks {
		if j.table[i].present && j.table[i].sector == from {
			off, seq, ok := j.emit_entry(i)
			if !ok {
				return false // burned slot(s); retry at the next quiet point
			}
			j.table[i].sector = j.active
			j.table[i].seq = seq
			if j.table[i].chained {
				j.table[i].ref_off = off
			}
		}
	}
	if was_clean {
		if !j.append_marker() {
			return false
		}
		j.tail_clean = true
	}
	return true
}

// --- internals -------------------------------------------------------------

// ensure_space: room for `n` contiguous records (a chain never straddles a
// compaction). Outside compaction a full sector triggers the inline compact
// ONLY when it is erase-free (clean partner) — quiet-point discipline.
fn (mut j Journal) ensure_space(n u32) bool {
	if j.max_seq >= seq_ceiling {
		return false // seq would wrap; the journal freezes rather than lie
	}
	if j.cursor + n * rec_size > j.cfg.size {
		if j.compacting {
			return false // a copy overflowing the target = capacity bug; refuse
		}
		if !j.partner_clean {
			return false // no erases in the append path; erase_pending() frees it
		}
		if !j.compact() {
			return false
		}
		if j.cursor + n * rec_size > j.cfg.size {
			return false
		}
	}
	return true
}

// emit_entry writes entry i's CURRENT value as fresh records into the active
// sector WITHOUT touching the pool (callers decide when to commit the new
// location). Returns (start offset, seq, ok).
fn (mut j Journal) emit_entry(i int) (u32, u32, bool) {
	if !j.table[i].chained {
		if !j.ensure_space(1) {
			return 0, 0, false
		}
		start := j.cursor
		seq := j.max_seq + 1
		j.max_seq = seq // consumed even on failure (a landed record must be outranked)
		mut rec := [32]u8{}
		encode_record(mut rec, j.table[i].id, j.table[i].len, seq, &j.table[i].data[0])
		if !j.program_slot(&rec[0]) {
			return 0, 0, false
		}
		return start, seq, true
	}
	// chained: copy part payloads verbatim from the immutable old location,
	// re-encoded under one fresh seq at the new cursor.
	nparts := chain_parts(j.table[i].len)
	if !j.ensure_space(nparts) {
		return 0, 0, false
	}
	old_base := j.sector_addr(j.table[i].sector) + j.table[i].ref_off
	start := j.cursor
	seq := j.max_seq + 1
	j.max_seq = seq
	mut old := [32]u8{}
	mut rec := [32]u8{}
	for k in u32(0) .. nparts {
		if !j.ops.read(j.ops.ctx, old_base + k * rec_size, &old[0], rec_size) {
			return 0, 0, false
		}
		blk, lenf, oseq, ok := parse_record(&old[0])
		if !ok || blk != j.table[i].id || oseq != j.table[i].seq
			|| lenf & chain_flag == 0 || u32((lenf >> part_shift) & 0x1F) != k {
			return 0, 0, false // rotted source: never copy garbage forward
		}
		encode_record_raw(mut rec, j.table[i].id, lenf, seq, &old[8])
		if !j.program_slot(&rec[0]) {
			return 0, 0, false
		}
	}
	return start, seq, true
}

// append_plain: a new <= 20 B value from the caller's buffer; pool installed
// only on success (an inline compact copies the OLD value by construction).
fn (mut j Journal) append_plain(block u16, data &u8, len u16) bool {
	if !j.ensure_space(1) {
		return false
	}
	i := j.slot_for(block)
	if i < 0 {
		return false // pool full (generation-gated)
	}
	j.dirty_tail_now()
	mut rec := [32]u8{}
	seq := j.max_seq + 1
	j.max_seq = seq
	encode_record(mut rec, block, len, seq, data)
	if !j.program_slot(&rec[0]) {
		return false
	}
	j.table[i].present = true
	j.table[i].id = block
	j.table[i].chained = false
	j.table[i].len = len
	for k in 0 .. int(len) {
		j.table[i].data[k] = unsafe { data[k] }
	}
	j.table[i].seq = seq
	j.table[i].sector = j.active
	return true
}

// append_chain: a new > 20 B value as contiguous parts under ONE seq; the
// whole-value CRC32 lands in the LAST part (completion evidence last). The
// pool is installed only after every part is durable — a cut anywhere leaves
// an incomplete run and the previous complete value wins at mount.
fn (mut j Journal) append_chain(block u16, data &u8, len u16) bool {
	nparts := chain_parts(len)
	if !j.ensure_space(nparts) {
		return false
	}
	i := j.slot_for(block)
	if i < 0 {
		return false
	}
	j.dirty_tail_now()
	whole := boot.crc32(data, u32(len))
	start := j.cursor
	seq := j.max_seq + 1
	j.max_seq = seq // one seq per logical write, consumed even on failure
	mut payload := [20]u8{}
	mut src := u32(0)
	mut rec := [32]u8{}
	for k in u32(0) .. nparts {
		mut p := u32(0)
		if k == 0 {
			payload[0] = u8(len)
			payload[1] = u8(len >> 8)
			p = 2
		}
		// data bytes for this part
		for p < data_max && src < u32(len) {
			payload[p] = unsafe { data[src] }
			p++
			src++
		}
		if src == u32(len) && k == nparts - 1 {
			// the whole-value CRC trailer (space guaranteed by chain_parts math)
			payload[p] = u8(whole)
			payload[p + 1] = u8(whole >> 8)
			payload[p + 2] = u8(whole >> 16)
			payload[p + 3] = u8(whole >> 24)
			p += 4
		}
		lenf := chain_flag | (u16(k) << part_shift) | u16(p)
		encode_record_raw(mut rec, block, lenf, seq, &payload[0])
		if !j.program_slot(&rec[0]) {
			return false
		}
	}
	j.table[i].present = true
	j.table[i].id = block
	j.table[i].chained = true
	j.table[i].len = len
	j.table[i].seq = seq
	j.table[i].sector = j.active
	j.table[i].ref_off = start
	return true
}

fn (mut j Journal) append_marker() bool {
	if !j.ensure_space(1) {
		return false
	}
	mut rec := [32]u8{}
	seq := j.max_seq + 1
	j.max_seq = seq
	encode_record(mut rec, marker_block, 0, seq, unsafe { nil })
	if !j.program_slot(&rec[0]) {
		return false
	}
	return true
}

// program_slot: one record at the cursor. The slot is consumed WHETHER OR NOT
// the program succeeds; a reported failure is READ-BACK-VERIFIED (landed
// intact = success). A burned slot reads as a torn record at the next mount.
fn (mut j Journal) program_slot(rec &u8) bool {
	addr := j.sector_addr(j.active) + j.cursor
	j.cursor += rec_size
	if j.ops.program(j.ops.ctx, addr, rec, rec_size) {
		return true
	}
	mut back := [32]u8{}
	if !j.ops.read(j.ops.ctx, addr, &back[0], rec_size) {
		return false
	}
	for i in 0 .. int(rec_size) {
		if back[i] != unsafe { rec[i] } {
			return false
		}
	}
	return true // the record is durably on flash: the failure was cosmetic
}

// slot_blank: is the record slot at addr erased? Driver blank-check preferred
// (DFLASH; ECC torn-but-reads-blank words). Fallback: read + all-0xFF test.
fn (mut j Journal) slot_blank(addr u32, rec &u8) bool {
	if j.ops.blank != unsafe { nil } {
		if j.ops.blank(j.ops.ctx, addr, rec_size) {
			return true
		}
		if !j.read_slot(addr, rec) {
			zero_rec(rec) // a failed read must not leave the previous slot's bytes
		}
		return false
	}
	if !j.read_slot(addr, rec) {
		zero_rec(rec)
		return false // unreadable = not blank; treated as dirt
	}
	for i in 0 .. int(rec_size) {
		if unsafe { rec[i] } != 0xFF {
			return false
		}
	}
	return true
}

// zero_rec: an all-zero buffer can never parse as a valid record.
fn zero_rec(rec &u8) {
	for i in 0 .. int(rec_size) {
		unsafe {
			rec[i] = 0
		}
	}
}

fn (mut j Journal) read_slot(addr u32, rec &u8) bool {
	return j.ops.read(j.ops.ctx, addr, rec, rec_size)
}

// encode_record: a PLAIN record (len is a byte count <= 20).
fn encode_record(mut rec [32]u8, block u16, len u16, seq u32, data &u8) {
	encode_record_raw(mut rec, block, len, seq, data)
}

// encode_record_raw: len_field passes through verbatim (chained encodings);
// the payload length actually copied is the low bits.
fn encode_record_raw(mut rec [32]u8, block u16, len_field u16, seq u32, data &u8) {
	for i in 0 .. 32 {
		rec[i] = 0
	}
	rec[0] = u8(block)
	rec[1] = u8(block >> 8)
	rec[2] = u8(len_field)
	rec[3] = u8(len_field >> 8)
	rec[4] = u8(seq)
	rec[5] = u8(seq >> 8)
	rec[6] = u8(seq >> 16)
	rec[7] = u8(seq >> 24)
	n := int(len_field & plen_mask)
	for i in 0 .. n {
		rec[8 + i] = unsafe { data[i] }
	}
	crc := boot.crc32(&rec[0], 28)
	rec[28] = u8(crc)
	rec[29] = u8(crc >> 8)
	rec[30] = u8(crc >> 16)
	rec[31] = u8(crc >> 24)
}

// parse_record: (block, len_field, seq, ok). A chained len-field is legal when
// its part length fits a record; a plain len must be <= 20.
fn parse_record(p &u8) (u16, u16, u32, bool) {
	blk := unsafe { u16(p[0]) | (u16(p[1]) << 8) }
	lenf := unsafe { u16(p[2]) | (u16(p[3]) << 8) }
	seq := unsafe { u32(p[4]) | (u32(p[5]) << 8) | (u32(p[6]) << 16) | (u32(p[7]) << 24) }
	crc := unsafe { u32(p[28]) | (u32(p[29]) << 8) | (u32(p[30]) << 16) | (u32(p[31]) << 24) }
	if lenf & chain_flag != 0 {
		if u32(lenf & plen_mask) > data_max {
			return 0, 0, 0, false
		}
	} else {
		if u32(lenf) > data_max {
			return 0, 0, 0, false
		}
	}
	if boot.crc32(p, 28) != crc {
		return 0, 0, 0, false
	}
	return blk, lenf, seq, true
}
