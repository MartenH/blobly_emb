module nvm

// @verifies REQ-NVM-002, REQ-NVM-003, REQ-NVM-012
// The journal engine against RAM-backed FlashOps — including the power-cut
// fuzz: cut every append at every byte offset, cut compaction after every
// program call, scramble an interrupted erase — remount and assert the
// invariant: THE LAST COMPLETE VALUE PER BLOCK WINS.

import boot

const sec_size = u32(1024) // 32 records/sector: small enough to force compaction
const a_addr = u32(0x1000)
const b_addr = u32(0x2000)

struct TestFlash {
mut:
	mem [2048]u8
	// power-cut injection: the Nth program call from now writes only `cut_bytes`
	// bytes and reports failure (0xFFFFFFFF = disabled)
	cut_call  u32 = 0xFFFF_FFFF
	cut_bytes u32
	calls     u32
}

fn off_of(addr u32) u32 {
	return if addr >= b_addr { addr - b_addr + sec_size } else { addr - a_addr }
}

fn tf_erase(ctx voidptr, addr u32, size u32) bool {
	mut f := unsafe { &TestFlash(ctx) }
	for i in u32(0) .. size {
		f.mem[off_of(addr) + i] = 0xFF
	}
	return true
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
	for i in u32(0) .. n {
		f.mem[off_of(addr) + i] = unsafe { data[i] }
	}
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

fn new_journal(mut f TestFlash) Journal {
	mut j := Journal{
		ops: boot.FlashOps{
			ctx:     f
			erase:   tf_erase
			program: tf_program
			read:    tf_read
		}
		cfg: SectorCfg{
			a_addr: a_addr
			b_addr: b_addr
			size:   sec_size
		}
	}
	for i in u32(0) .. 2 * sec_size {
		f.mem[i] = 0xFF // factory-fresh flash
	}
	assert j.mount()
	return j
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

fn remount(mut f TestFlash) Journal {
	mut j := Journal{
		ops: boot.FlashOps{
			ctx:     f
			erase:   tf_erase
			program: tf_program
			read:    tf_read
		}
		cfg: SectorCfg{
			a_addr: a_addr
			b_addr: b_addr
			size:   sec_size
		}
	}
	assert j.mount()
	return j
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
	// survives remount (REQ-NVM-001's storage half): latest per block wins
	mut j2 := remount(mut f)
	assert getv(j2, 1)? == 102
	assert getv(j2, 2)? == 200
	assert !j2.clean // records after (no) marker -> the session didn't sleep
}

// The power-cut fuzz (REQ-NVM-003): cut the append of a NEW value at every
// byte offset; the OLD value must win at remount for every partial write.
fn test_power_cut_during_append() {
	for cut in u32(0) .. 32 {
		mut f := &TestFlash{}
		mut j := new_journal(mut f)
		putv(mut j, 1, 0xAAAA_0001)
		putv(mut j, 2, 0xBBBB_0001)
		f.cut_call = f.calls + 1 // the very next program call...
		f.cut_bytes = cut // ...writes only `cut` bytes, then power dies
		data := [u8(0x02), 0x00, 0xCC, 0xCC]
		assert !j.put(1, &data[0], 4) // the engine reports the failure
		mut j2 := remount(mut f)
		assert getv(j2, 1)? == 0xAAAA_0001, 'cut at ${cut}: old value must win'
		assert getv(j2, 2)? == 0xBBBB_0001
	}
}

// Fill past the sector: compaction happens inline, values survive, the old
// sector awaits its erase, and writes keep landing THROUGHOUT (REQ-NVM-012).
fn test_compaction_and_writes_during_gc() {
	mut f := &TestFlash{}
	mut j := new_journal(mut f)
	for i in u32(0) .. 40 { // 40 appends > 32 slots -> at least one compaction
		putv(mut j, u16(1 + (i % 3)), 0x1000 + i)
	}
	assert j.pending_erase >= 0 // GC ran, erase deferred to the quiet point
	// writes DURING the pending-erase window are ordinary appends
	putv(mut j, 2, 0xFEED)
	assert getv(j, 2)? == 0xFEED
	// a remount in this state unions both sectors and re-homes strays
	mut j2 := remount(mut f)
	assert getv(j2, 2)? == 0xFEED
	assert getv(j2, 1)? == 0x1000 + 39 - (39 % 3) + 0 // last write to block 1
	// the quiet point
	assert j2.erase_pending()
	mut j3 := remount(mut f)
	assert getv(j3, 2)? == 0xFEED
}

// Cut compaction after EVERY program call: remount must recover every value
// (mount completes the copy; the erase stays pending).
fn test_power_cut_during_compaction() {
	for cut_after in u32(1) .. 8 {
		mut f := &TestFlash{}
		mut j := new_journal(mut f)
		putv(mut j, 1, 111)
		putv(mut j, 2, 222)
		putv(mut j, 3, 333)
		f.cut_call = f.calls + cut_after
		f.cut_bytes = 16 // die halfway through that record
		// force a compaction now (ignore its reported failure — power died)
		j.compact()
		mut j2 := remount(mut f)
		assert getv(j2, 1)? == 111, 'cut after ${cut_after} programs'
		assert getv(j2, 2)? == 222
		assert getv(j2, 3)? == 333
	}
}

// An interrupted ERASE leaves garbage beyond the append frontier: mount must
// classify the sector dirty (pending erase), never append into it, and lose
// nothing (the values were already copied out).
fn test_interrupted_erase_detected() {
	mut f := &TestFlash{}
	mut j := new_journal(mut f)
	putv(mut j, 1, 41)
	putv(mut j, 2, 42)
	assert j.compact() // values now live in sector B; A pending erase
	old := j.pending_erase
	assert old == 0
	// simulate a half-done erase of A: head erased, dirt in the middle
	for i in u32(0) .. 256 {
		f.mem[i] = 0xFF
	}
	f.mem[300] = 0x5A
	f.mem[301] = 0xA5
	mut j2 := remount(mut f)
	assert getv(j2, 1)? == 41
	assert getv(j2, 2)? == 42
	assert j2.pending_erase == 0 // the dirt is seen and scheduled
	assert j2.erase_pending()
	mut j3 := remount(mut f)
	assert j3.pending_erase == -1
	assert getv(j3, 1)? == 41
}

// Clean-shutdown semantics: clean iff the newest record is the marker.
fn test_clean_marker() {
	mut f := &TestFlash{}
	mut j := new_journal(mut f)
	putv(mut j, 1, 7)
	assert j.mark_clean()
	mut j2 := remount(mut f)
	assert j2.clean
	assert getv(j2, 1)? == 7
	// waking up and writing again makes the session unclean-by-tail
	putv(mut j2, 1, 8)
	mut j3 := remount(mut f)
	assert !j3.clean
	assert getv(j3, 1)? == 8
}

// Corrupt stored data (bit rot, not a torn append): CRC rejects the record and
// OLDER data wins; with no older record the block reads absent -> the caller's
// declared default (REQ-NVM-002).
fn test_corrupt_record_rejected() {
	mut f := &TestFlash{}
	mut j := new_journal(mut f)
	putv(mut j, 1, 500)
	f.mem[8] ^= 0x01 // flip a data bit of the only record for block 1
	mut j2 := remount(mut f)
	assert getv(j2, 1) == none // absent -> default at the persistence layer
	putv(mut j, 2, 600)
	putv(mut j, 2, 601)
	// corrupt only the NEWEST record of block 2 -> the older one wins
	// (records are appended sequentially: find it via the cursor)
	f.mem[j.cursor - 32 + 8] ^= 0x01
	mut j3 := remount(mut f)
	assert getv(j3, 2)? == 600
}

// The headroom arithmetic the watermark policy builds on (REQ-NVM-011's
// engine half): free/live record counts.
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
