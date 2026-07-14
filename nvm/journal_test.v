module nvm

// @verifies REQ-NVM-002, REQ-NVM-003, REQ-NVM-012
// The journal engine against RAM-backed FlashOps. The TestFlash enforces one
// invariant EVERYWHERE: no flash word is ever programmed twice (double_prog
// latches if any programmed byte wasn't erased) — the ECC-legality rule the
// 2026-07-15 review round circled. Plus the fuzz: every append cut at every
// byte offset, compaction cut after every program, transient failures,
// interrupted erases, the blank-hook (DFLASH/ECC weak-read) path, capacity
// refusal, marker preservation across compaction.

import boot

const sec_size = u32(1024) // 32 records/sector: small enough to force compaction
const a_addr = u32(0x1000)
const b_addr = u32(0x2000)

struct TestFlash {
mut:
	mem [2048]u8
	// power-cut / transient-failure injection: the Nth program call from now
	// writes only cut_bytes bytes and reports failure (0xFFFFFFFF = disabled)
	cut_call  u32 = 0xFFFF_FFFF
	cut_bytes u32
	calls     u32
	// erase injection: the next erase wipes only half and reports failure
	erase_cut bool
	// invariant latch: some program touched a non-erased byte (ECC-illegal)
	double_prog bool
	// per-word touched metadata for the DFLASH-style blank hook
	touched [64]bool
	// simulate H7 weak charge: touched words whose cells hold no data READ as
	// 0xFF (only sane with the blank hook — the trap the hook exists for)
	weak_reads bool
	// latch double_prog on TOUCHED words too (hook-mode tests): the pattern
	// fallback cannot detect a zero-byte pulse by contract, so this stays off
	// for no-hook tests
	strict_touch bool
}

fn off_of(addr u32) u32 {
	return if addr >= b_addr { addr - b_addr + sec_size } else { addr - a_addr }
}

fn tf_erase(ctx voidptr, addr u32, size u32) bool {
	mut f := unsafe { &TestFlash(ctx) }
	// erase_cut: the erase dies after wiping only the SECOND half — the head
	// (where records live) survives, the classic partially-erased sector.
	start := if f.erase_cut { size / 2 } else { u32(0) }
	cut := f.erase_cut
	f.erase_cut = false
	for i in start .. size {
		f.mem[off_of(addr) + i] = 0xFF
	}
	for w in start / 32 .. size / 32 {
		f.touched[(off_of(addr) + w * 32) / 32] = false
	}
	return !cut
}

fn tf_program(ctx voidptr, addr u32, data &u8, len u32) bool {
	mut f := unsafe { &TestFlash(ctx) }
	f.calls++
	mut n := len
	mut fail := false
	if f.calls == f.cut_call {
		n = f.cut_bytes
		fail = true
	}
	if f.strict_touch && f.touched[off_of(addr) / 32] {
		f.double_prog = true // the word was pulsed before: ECC-illegal
	}
	for i in u32(0) .. n {
		if f.mem[off_of(addr) + i] != 0xFF {
			f.double_prog = true
		}
		f.mem[off_of(addr) + i] = unsafe { data[i] }
	}
	// the pulse fired even on a cut — the word counts as touched
	f.touched[off_of(addr) / 32] = true
	return !fail
}

fn tf_read(ctx voidptr, addr u32, out &u8, len u32) bool {
	f := unsafe { &TestFlash(ctx) }
	for i in u32(0) .. len {
		unsafe {
			out[i] = f.mem[off_of(addr) + i]
		}
	}
	return true
}

// the DFLASH/ECC-style hardware blank-check: a touched word is NOT blank,
// regardless of what its cells read back.
fn tf_blank(ctx voidptr, addr u32, len u32) bool {
	f := unsafe { &TestFlash(ctx) }
	for w in u32(0) .. len / 32 {
		if f.touched[(off_of(addr) + w * 32) / 32] {
			return false
		}
	}
	for i in u32(0) .. len {
		if f.mem[off_of(addr) + i] != 0xFF {
			return false
		}
	}
	return true
}

fn make_ops(mut f TestFlash, with_blank bool) boot.FlashOps {
	mut ops := boot.FlashOps{
		ctx:     f
		erase:   tf_erase
		program: tf_program
		read:    tf_read
	}
	if with_blank {
		ops.blank = tf_blank
	}
	return ops
}

fn fresh(mut f TestFlash, with_blank bool) Journal {
	for i in u32(0) .. 2 * sec_size {
		f.mem[i] = 0xFF
	}
	for i in 0 .. 64 {
		f.touched[i] = false
	}
	mut j := Journal{
		ops: make_ops(mut f, with_blank)
		cfg: SectorCfg{
			a_addr: a_addr
			b_addr: b_addr
			size:   sec_size
		}
	}
	assert j.mount()
	return j
}

fn new_journal(mut f TestFlash) Journal {
	return fresh(mut f, false)
}

fn remount_with(mut f TestFlash, with_blank bool) Journal {
	mut j := Journal{
		ops: make_ops(mut f, with_blank)
		cfg: SectorCfg{
			a_addr: a_addr
			b_addr: b_addr
			size:   sec_size
		}
	}
	assert j.mount()
	return j
}

fn remount(mut f TestFlash) Journal {
	return remount_with(mut f, false)
}

fn putv(mut j Journal, block u16, v u32) {
	data := [u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24)]
	assert j.put(block, &data[0], 4)
}

fn getv(j Journal, block u16) ?u32 {
	mut out := [4]u8{}
	n := j.get(block, &out[0], 4)
	if n == 0 {
		return none
	}
	return u32(out[0]) | (u32(out[1]) << 8) | (u32(out[2]) << 16) | (u32(out[3]) << 24)
}

fn test_roundtrip_and_latest_wins() {
	mut f := &TestFlash{}
	mut j := new_journal(mut f)
	assert j.clean // fresh journal counts as clean
	putv(mut j, 1, 100)
	putv(mut j, 2, 200)
	putv(mut j, 1, 101)
	putv(mut j, 1, 102)
	assert getv(j, 1)? == 102
	assert getv(j, 2)? == 200
	assert getv(j, 3) == none
	mut j2 := remount(mut f)
	assert getv(j2, 1)? == 102
	assert getv(j2, 2)? == 200
	assert !j2.clean
	assert !f.double_prog
}

// The power-cut fuzz (REQ-NVM-003): cut the append of a NEW value at every
// byte offset; the OLD value must win — immediately (table rollback) and at
// remount — and the burned slot must never be re-programmed.
fn test_power_cut_during_append() {
	for cut in u32(0) .. 32 {
		mut f := &TestFlash{}
		mut j := new_journal(mut f)
		putv(mut j, 1, 0xAAAA_0001)
		putv(mut j, 2, 0xBBBB_0001)
		f.cut_call = f.calls + 1
		f.cut_bytes = cut
		data := [u8(0x02), 0x00, 0xCC, 0xCC]
		assert !j.put(1, &data[0], 4)
		assert getv(j, 1)? == 0xAAAA_0001 // rollback: a failed put is not served
		mut j2 := remount(mut f)
		assert getv(j2, 1)? == 0xAAAA_0001, 'cut at ${cut}: old value must win'
		assert getv(j2, 2)? == 0xBBBB_0001
		// life continues: the torn slot is consumed, the next append lands past it
		putv(mut j2, 1, 0xAAAA_0002)
		assert getv(j2, 1)? == 0xAAAA_0002
		assert !f.double_prog, 'cut at ${cut}: a slot was programmed twice'
	}
}

// A transient driver failure (writes nothing, reports false) burns the slot:
// the put fails cleanly, a retry succeeds in the NEXT slot, no double program.
fn test_transient_program_failure_burns_slot() {
	mut f := &TestFlash{}
	mut j := new_journal(mut f)
	putv(mut j, 1, 1)
	f.cut_call = f.calls + 1
	f.cut_bytes = 0
	data := [u8(2), 0, 0, 0]
	assert !j.put(1, &data[0], 4)
	assert getv(j, 1)? == 1
	putv(mut j, 1, 3) // the retry lands in a fresh slot
	assert getv(j, 1)? == 3
	mut j2 := remount(mut f)
	assert getv(j2, 1)? == 3
	assert !f.double_prog
}

// Exact-fill then keep writing: the inline compact must leave room and the
// post-compact re-check must hold (the past-the-sector-end program bug).
fn test_exact_fill_boundary() {
	mut f := &TestFlash{}
	mut j := new_journal(mut f)
	for b in u16(1) .. 25 {
		putv(mut j, b, u32(b))
	}
	for i in u32(0) .. 8 {
		putv(mut j, 1, 100 + i)
	}
	assert j.free_records() == 0 // sector A exactly full
	putv(mut j, 2, 999) // triggers the inline compact; 25 live records fit
	assert getv(j, 2)? == 999
	for b in u16(3) .. 25 {
		assert getv(j, b)? == u32(b)
	}
	mut j2 := remount(mut f)
	assert getv(j2, 1)? == 107
	assert getv(j2, 2)? == 999
	assert !f.double_prog
}

// A live set that cannot fit one sector must REFUSE (no recursion, no OOB):
// the engine's guard behind the generator's capacity gate.
fn test_capacity_refusal() {
	mut f := &TestFlash{}
	mut j := new_journal(mut f)
	mut refused := false
	for b in u16(1) .. 40 {
		data := [u8(b), 0, 0, 0]
		if !j.put(b, &data[0], 4) {
			refused = true
			break
		}
	}
	assert refused
	assert !f.double_prog
	mut j2 := remount(mut f)
	assert getv(j2, 1)? == 1 // what fit stays consistent
}

// Cut compaction after EVERY program call: compact reports failure, the
// journal REVERTS to the intact old sector, values survive immediately and
// across remount, and recovery converges.
fn test_power_cut_during_compaction() {
	for cut_after in u32(1) .. 4 { // the copy is exactly 3 programs (3 blocks)
		mut f := &TestFlash{}
		mut j := new_journal(mut f)
		putv(mut j, 1, 111)
		putv(mut j, 2, 222)
		putv(mut j, 3, 333)
		f.cut_call = f.calls + cut_after
		f.cut_bytes = 16
		assert !j.compact()
		f.cut_call = 0xFFFF_FFFF // power restored: no further injection
		assert getv(j, 1)? == 111 // reverted, still serving
		assert getv(j, 2)? == 222
		assert getv(j, 3)? == 333
		mut j2 := remount(mut f) // or power died right there: remount as-is
		assert getv(j2, 1)? == 111, 'cut after ${cut_after} programs'
		assert getv(j2, 2)? == 222
		assert getv(j2, 3)? == 333
		assert j2.erase_pending() // quiet point: cleanup...
		assert j2.compact() // ...and a fresh compact converges
		mut j3 := remount(mut f)
		assert getv(j3, 3)? == 333
		assert !f.double_prog, 'cut after ${cut_after}: double program'
	}
}

// A transient failure mid-compact must not poison the NEXT compact (the stale
// partner_clean bug): the retry erases the half-written target instead of
// programming over it.
fn test_failed_compact_then_retry() {
	mut f := &TestFlash{}
	mut j := new_journal(mut f)
	putv(mut j, 1, 11)
	putv(mut j, 2, 22)
	f.cut_call = f.calls + 2
	f.cut_bytes = 0
	assert !j.compact()
	assert getv(j, 1)? == 11
	assert getv(j, 2)? == 22
	assert j.compact() // retry: must erase the dirty target first
	assert getv(j, 1)? == 11
	assert j.erase_pending()
	mut j2 := remount(mut f)
	assert getv(j2, 1)? == 11
	assert getv(j2, 2)? == 22
	assert !f.double_prog
}

// Strays after an interrupted compaction: mount is READ-ONLY (the union table
// serves them); erase_pending() re-homes via compact instead of orphaning.
fn test_strays_rehomed_at_quiet_point() {
	mut f := &TestFlash{}
	mut j := new_journal(mut f)
	putv(mut j, 1, 51)
	putv(mut j, 2, 52)
	f.cut_call = f.calls + 2 // die mid-copy
	f.cut_bytes = 16
	j.compact()
	mut j2 := remount(mut f)
	assert getv(j2, 1)? == 51
	assert getv(j2, 2)? == 52
	assert j2.erase_pending() // compacts when strays exist, erases otherwise
	assert getv(j2, 1)? == 51
	assert getv(j2, 2)? == 52
	mut j3 := remount(mut f)
	assert getv(j3, 1)? == 51
	assert getv(j3, 2)? == 52
	assert !f.double_prog
}

// Clean-shutdown semantics: clean iff the newest record is the marker — and
// the marker SURVIVES compaction (the dropped-marker bug), including a
// mark_clean that itself triggers the inline compact (seq allocated AFTER
// the copy, so the marker still ends newest).
fn test_clean_marker_survives_compaction() {
	mut f := &TestFlash{}
	mut j := new_journal(mut f)
	putv(mut j, 1, 7)
	assert j.mark_clean()
	assert j.compact()
	mut j2 := remount(mut f)
	assert j2.clean
	assert getv(j2, 1)? == 7
	mut f2 := &TestFlash{}
	mut j3 := new_journal(mut f2)
	putv(mut j3, 1, 9)
	for j3.free_records() > 0 {
		putv(mut j3, 2, j3.free_records())
	}
	assert j3.mark_clean() // full sector: inline compact + marker
	mut j4 := remount(mut f2)
	assert j4.clean
	assert getv(j4, 1)? == 9
	assert !f2.double_prog
}

fn test_wake_after_clean_is_unclean() {
	mut f := &TestFlash{}
	mut j := new_journal(mut f)
	putv(mut j, 1, 7)
	assert j.mark_clean()
	mut j2 := remount(mut f)
	assert j2.clean
	putv(mut j2, 1, 8)
	mut j3 := remount(mut f)
	assert !j3.clean
	assert getv(j3, 1)? == 8
}

// An interrupted ERASE (half-wiped sector) is detected as dirt, never
// appended into, and rescheduled — injected through the erase hook itself.
fn test_interrupted_erase_detected() {
	mut f := &TestFlash{}
	mut j := new_journal(mut f)
	putv(mut j, 1, 41)
	putv(mut j, 2, 42)
	assert j.compact() // values in B; A pending
	f.erase_cut = true
	assert !j.erase_pending() // the erase died halfway
	mut j2 := remount(mut f)
	assert getv(j2, 1)? == 41
	assert getv(j2, 2)? == 42
	assert j2.pending_erase == 0 // the dirt is seen and rescheduled
	assert j2.erase_pending()
	mut j3 := remount(mut f)
	assert j3.pending_erase == -1
	assert getv(j3, 1)? == 41
	assert !f.double_prog
}

// The blank-hook (DFLASH/ECC) path: a torn word whose cells READ erased must
// still classify non-blank (touched), so the frontier moves past it and no
// word is ever programmed twice — the H7 weak-charge trap.
fn test_blank_hook_weak_frontier() {
	mut f := &TestFlash{}
	f.strict_touch = true
	mut j := fresh(mut f, true)
	putv(mut j, 1, 61)
	// a cut append whose pulse fired but left no readable data
	f.cut_call = f.calls + 1
	f.cut_bytes = 0
	data := [u8(62), 0, 0, 0]
	assert !j.put(1, &data[0], 4)
	f.weak_reads = true // from now on the torn word reads all-FF
	mut j2 := remount_with(mut f, true)
	assert getv(j2, 1)? == 61
	putv(mut j2, 1, 63) // must land BEYOND the touched-but-blank-reading word
	assert getv(j2, 1)? == 63
	mut j3 := remount_with(mut f, true)
	assert getv(j3, 1)? == 63
	assert !f.double_prog, 'the weak frontier word was programmed twice'
}

// Corrupt stored data (bit rot): CRC rejects the record and OLDER data wins;
// with no older record the block reads absent -> declared default.
fn test_corrupt_record_rejected() {
	mut f := &TestFlash{}
	mut j := new_journal(mut f)
	putv(mut j, 1, 500)
	f.mem[8] ^= 0x01
	mut j2 := remount(mut f)
	assert getv(j2, 1) == none
	putv(mut j, 2, 600)
	putv(mut j, 2, 601)
	f.mem[j.cursor - 32 + 8] ^= 0x01 // corrupt only the newest record of block 2
	mut j3 := remount(mut f)
	assert getv(j3, 2)? == 600
}

// API misuse is refused, never a crash: pre-mount calls (nil ops!), len 0,
// the marker block, out-of-range blocks.
fn test_misuse_guards() {
	mut j := Journal{} // zero value: nil ops, not mounted
	data := [u8(1), 2, 3, 4]
	mut out := [4]u8{}
	assert !j.put(1, &data[0], 4)
	assert j.get(1, &out[0], 4) == 0
	assert !j.compact()
	assert !j.mark_clean()
	assert !j.erase_pending()
	assert !j.mount() // nil ops refused
	mut f := &TestFlash{}
	mut j2 := new_journal(mut f)
	assert !j2.put(0, &data[0], 4) // the marker block is not writable
	assert !j2.put(1, &data[0], 0) // empty = indistinguishable from absent
	assert !j2.put(u16(max_blocks), &data[0], 4)
	assert !f.double_prog
}

// The headroom arithmetic the watermark policy builds on (REQ-NVM-011's
// engine half).
fn test_headroom_numbers() {
	mut f := &TestFlash{}
	mut j := new_journal(mut f)
	assert j.free_records() == 32
	putv(mut j, 1, 1)
	putv(mut j, 2, 2)
	putv(mut j, 2, 3)
	assert j.free_records() == 29
	assert j.live_records() == 3 // blocks 1 + 2 + the marker's slot
}

// Codex P1 pair: clean-semantics honesty. (1) An all-torn journal is NOT
// clean; (2) a torn write AFTER the marker (woke, died mid-put) is NOT clean —
// while a burned slot in the OLD sector's tail must not poison cleanliness.
fn test_clean_is_honest() {
	// (1) content but zero valid records -> unclean
	mut f := &TestFlash{}
	mut j := new_journal(mut f)
	putv(mut j, 1, 1)
	f.mem[0 + 8] ^= 0x01 // corrupt the only record
	mut j2 := remount(mut f)
	assert getv(j2, 1) == none
	assert !j2.clean
	// (2) clean marker, then a torn append -> unclean
	mut f2 := &TestFlash{}
	mut j3 := new_journal(mut f2)
	putv(mut j3, 1, 5)
	assert j3.mark_clean()
	f2.cut_call = f2.calls + 1
	f2.cut_bytes = 7 // the wake's first write dies mid-word
	data := [u8(6), 0, 0, 0]
	assert !j3.put(1, &data[0], 4)
	mut j4 := remount(mut f2)
	assert !j4.clean, 'a torn post-marker write must read unclean'
	assert getv(j4, 1)? == 5
	// (3) a clean shutdown stays clean even with a burned slot in the OLD
	// sector: fail one put, then compact, then mark clean
	mut f3 := &TestFlash{}
	mut j5 := new_journal(mut f3)
	putv(mut j5, 1, 8)
	f3.cut_call = f3.calls + 1
	f3.cut_bytes = 3
	bad := [u8(9), 0, 0, 0]
	assert !j5.put(1, &bad[0], 4) // burned slot in sector A
	putv(mut j5, 1, 9)
	assert j5.compact() // values move to B; A (with its burned tail) pending
	assert j5.mark_clean()
	mut j6 := remount(mut f3)
	assert j6.clean, 'old-sector debris must not poison a clean shutdown'
	assert getv(j6, 1)? == 9
}

// Codex round-2 P1 trio.
// (1) An inline compact must NOT durably persist an uncommitted put value:
// fill the sector, then cut the put's OWN record program (which lands after
// the compact) — the compact's copy must carry the OLD value.
fn test_compact_never_persists_uncommitted_put() {
	mut f := &TestFlash{}
	mut j := new_journal(mut f)
	putv(mut j, 1, 0xE1)
	for j.free_records() > 0 {
		putv(mut j, 2, j.free_records())
	}
	// next put: ensure_space compacts (2 copies = 2 programs), then programs
	// the new record as the 3rd call — cut exactly there
	f.cut_call = f.calls + 3
	f.cut_bytes = 0
	data := [u8(0xE2), 0, 0, 0]
	assert !j.put(1, &data[0], 4)
	assert getv(j, 1)? == 0xE1 // not served...
	mut j2 := remount(mut f)
	assert getv(j2, 1)? == 0xE1, 'the compact copy leaked an uncommitted value'
	assert !f.double_prog
}

// (2) erase_pending re-homes strays BEFORE erasing: if the erase itself dies
// (or power cuts anywhere in the order), every value has a durable copy.
fn test_erase_pending_rehomes_before_erase() {
	mut f := &TestFlash{}
	mut j := new_journal(mut f)
	putv(mut j, 1, 71)
	putv(mut j, 2, 72)
	f.cut_call = f.calls + 2 // interrupt the compaction copy -> strays remain
	f.cut_bytes = 16
	j.compact()
	f.cut_call = 0xFFFF_FFFF
	mut j2 := remount(mut f)
	f.erase_cut = true // the erase after the re-home dies...
	assert !j2.erase_pending()
	mut j3 := remount(mut f) // ...and power is lost right there
	assert getv(j3, 1)? == 71, 'a stray lost its only durable copy'
	assert getv(j3, 2)? == 72
	assert j3.erase_pending() // recovery converges
	mut j4 := remount(mut f)
	assert getv(j4, 1)? == 71
	assert !f.double_prog
}

// (3) A FAILED post-marker write still dirties the tail: a later compact must
// not re-append the marker over the evidence.
fn test_failed_post_marker_write_dirties_tail() {
	mut f := &TestFlash{}
	mut j := new_journal(mut f)
	putv(mut j, 1, 81)
	assert j.mark_clean()
	f.cut_call = f.calls + 1
	f.cut_bytes = 5 // the wake's write tears
	data := [u8(82), 0, 0, 0]
	assert !j.put(1, &data[0], 4)
	assert j.compact() // must NOT restore the clean tail
	mut j2 := remount(mut f)
	assert !j2.clean, 'a failed post-marker write was erased from history'
	assert getv(j2, 1)? == 81
	assert !f.double_prog
}
