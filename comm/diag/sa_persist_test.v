module diag

import boot
import nvm
import comm.uds

// @verifies REQ-DIAG-033 REQ-DIAG-065 REQ-DIAG-067 REQ-DIAG-068
// (the 0x27 state in the real NvM journal: a power cut anywhere — a write, a compaction, an erase,
//  the boot's own re-home and erase — restores the record last acknowledged or the one being
//  written, and a pass that reports the state stored has it in the journal before its answer is
//  pumped; an ECUReset's flush takes the state
//  across the reset, the block survives the boot's prune; a sustained wrong-key stream writes at
//  most the attempts, so it never fills the journal and another writer's put is still accepted
//  after hours of it; and a journal another writer filled never erases at run time for the state:
//  keys are judged as ever and their counts held in RAM until the flush before an ECUReset, or an
//  NM node's sleep edge, frees it and takes them, while a power cut meanwhile restores the record
//  last accepted — a clear it refused costing a delay, never a key.)

const sp_block = u16(0x044E) // nvm_hash16("uds:security"), the generator's fixed block
const sp_other = u16(0x0F00) // a stand-in for another writer (the fault memory, a coding)
const sp_retry_us = u64(100_000)

// SFlash is RAM flash with a power cut: the program call numbered `cut_at` writes part of its
// record, or the erase numbered `cut_erase` erases part of its sector, and the power is gone.
struct SFlash {
mut:
	mem       [2048]u8
	calls     u32
	cut_at    u32 // 0 = no cut armed
	cut_part  u32
	erases    u32
	cut_erase u32 // 0 = no cut armed
	dead      bool
}

fn sf_erase(ctx voidptr, addr u32, size u32) bool {
	mut f := unsafe { &SFlash(ctx) }
	if f.dead {
		return false
	}
	f.erases++
	mut n := size
	if f.cut_erase != 0 && f.erases == f.cut_erase {
		n = size / 2
		f.dead = true
	}
	for i in 0 .. n {
		f.mem[addr + i] = 0xFF
	}
	return !f.dead
}

fn sf_program(ctx voidptr, addr u32, data &u8, len u32) bool {
	mut f := unsafe { &SFlash(ctx) }
	if f.dead {
		return false
	}
	f.calls++
	mut n := len
	if f.cut_at != 0 && f.calls == f.cut_at {
		n = f.cut_part % (len + 1)
		f.dead = true
	}
	for i in 0 .. n {
		f.mem[addr + i] = unsafe { data[i] }
	}
	return !f.dead
}

fn sf_read(ctx voidptr, addr u32, out &u8, len u32) bool {
	f := unsafe { &SFlash(ctx) }
	for i in 0 .. len {
		unsafe {
			out[i] = f.mem[addr + i]
		}
	}
	return true
}

// SRig is one ECU: the flash outlives a power cut; the journal and the server do not. `ack` is
// the record the journal last acknowledged, `inflight` the one a cut interrupted.
@[heap]
struct SRig {
mut:
	f        SFlash
	j        nvm.Journal
	srv      uds.Server
	sa       uds.ReferenceSecurity
	sector   u32
	now      u64
	ack      []u8
	pending  []u8
	inflight []u8
	puts     int
	nm       bool // an NM node: the boot neither erases nor compacts (its sleep edges do)
	// boots a power cut interrupted inside the journal's own work (mount, prune, re-home, erase,
	// compaction)
	boot_cuts int
}

fn srig_put(ctx voidptr, id u16, data &u8, len u16) bool {
	mut r := unsafe { &SRig(ctx) }
	r.pending = unsafe { data.vbytes(int(len)) }.clone()
	ok := r.j.put(id, data, len)
	if ok {
		r.ack = r.pending.clone()
		r.puts++
	} else if r.f.dead {
		r.inflight = r.pending.clone()
	}
	return ok
}

fn srig_get(ctx voidptr, id u16, out &u8, cap u16) u16 {
	r := unsafe { &SRig(ctx) }
	return r.j.get(id, out, cap)
}

fn new_srig(sector u32) &SRig {
	mut r := &SRig{
		sector: sector
		now:    1_000_000
	}
	for b in 0 .. r.f.mem.len {
		r.f.mem[b] = 0xFF
	}
	r.boot()
	return r
}

// boot: the journal mounted and pruned to this firmware's blocks; without NM a sector a compaction
// left behind erased, and past half a sector used compacted and erased too (an NM node erases at
// its sleep edges instead) — the generated boot's order — then the server configured, its 0x27
// state restored before the first request, and ticked.
fn (mut r SRig) boot() {
	r.boot_cut(0, 0)
}

// boot_cut: a boot whose journal work is cut by a power cut at its `at`-th flash program or
// `erase`-th erase from now (0 = none) — then the next power-up, uncut. A cut armed for work the
// boot did not have is disarmed before the server runs.
fn (mut r SRig) boot_cut(at u32, erase u32) {
	r.f.dead = false
	r.f.cut_at = if at != 0 { r.f.calls + at } else { 0 }
	r.f.cut_erase = if erase != 0 { r.f.erases + erase } else { 0 }
	r.j = nvm.Journal{}
	r.j.ops = boot.FlashOps{
		ctx:     &r.f
		erase:   sf_erase
		program: sf_program
		read:    sf_read
	}
	r.j.cfg = nvm.SectorCfg{
		a_addr: 0
		b_addr: r.sector
		size:   r.sector
	}
	if r.j.mount() {
		keep := [sp_block, sp_other]!
		r.j.prune(&keep[0], 2)
		if !r.nm {
			r.j.boot_erase_point()
		}
	}
	r.f.cut_at = 0
	r.f.cut_erase = 0
	if r.f.dead {
		r.boot_cuts++
		r.boot_cut(0, 0) // the power comes back
		return
	}
	r.srv = uds.Server{}
	r.srv.init(256)
	r.srv.security = r.sa.ops(u32(r.now) | 1)
	r.srv.security_levels = 0x01
	r.srv.sa_delay_us = 1_000_000
	r.srv.sa_store = uds.SecurityStore{
		ctx:      unsafe { voidptr(r) }
		put:      srig_put
		get:      srig_get
		id:       sp_block
		retry_us: sp_retry_us
	}
	r.srv.restore_persisted_security()
	r.srv.tick(r.now)
	r.call([u8(0x10), 0x03])
}

fn (mut r SRig) call(req []u8) []u8 {
	mut resp := [64]u8{}
	n := r.srv.handle(&req[0], req.len, &resp[0])
	mut out := []u8{}
	for i in 0 .. n {
		out << resp[i]
	}
	return out
}

fn (mut r SRig) key(right bool) []u8 {
	r.call([u8(0x10), 0x03])
	s := r.call([u8(0x27), 0x01])
	if s.len < 6 || s[0] != 0x67 {
		return s
	}
	mut req := [u8(0x27), 0x02]
	for b in s[2..] {
		req << if right { b ^ 0xFF } else { b ^ 0xFE }
	}
	return r.call(req)
}

// pass: the pass's persist step, after its requests and before its answer is pumped
fn (mut r SRig) pass() bool {
	return r.srv.persist_security(false)
}

// quiet_flush: the flush the generated choreography runs at an ECUReset once its answer is on the
// wire and at an NM node's sleep edge (nvm_flush_choreo with its erase) — the state written, a
// refusal earning ONE erase of the sector a compaction left behind and a retry, and the deferred
// erase last; true when the state is durable and the power held.
fn (mut r SRig) quiet_flush() bool {
	mut ok := r.srv.persist_security(true)
	if !ok {
		r.j.erase_pending()
		ok = r.srv.persist_security(true)
	}
	r.j.erase_pending() // the deferred erase, after values and marker are durable
	return ok && !r.f.dead
}

fn (r &SRig) stored() []u8 {
	mut b := [16]u8{}
	n := r.j.get(sp_block, &b[0], 16)
	mut out := []u8{}
	for i in 0 .. int(n) {
		out << b[i]
	}
	return out
}

fn (r &SRig) record() []u8 {
	rec := r.srv.sa_record()
	mut out := []u8{}
	for b in rec {
		out << b
	}
	return out
}

// held: what the journal holds, as the server reads it — no record is the zero record
fn (r &SRig) held() []u8 {
	if r.ack.len > 0 {
		return r.ack
	}
	mut z := [uds.sa_record_format, u8(uds.max_security_level)]
	for _ in 0 .. uds.max_security_level {
		z << 0
	}
	return z
}

struct SRng {
mut:
	s u32
}

fn (mut g SRng) next(n u32) u32 {
	g.s ^= g.s << 13
	g.s ^= g.s >> 17
	g.s ^= g.s << 5
	return g.s % n
}

// after a boot: the journal holds the record last acknowledged, or the one a cut interrupted, and
// the server runs from exactly that record (the delay it arms already started by the first tick)
fn (mut r SRig) check_boot(step int) {
	got := r.stored()
	if r.inflight.len > 0 && got == r.inflight {
		r.ack = got.clone() // the interrupted write had reached the journal whole
	}
	assert got == r.ack, 'step ${step}: restored ${got}, acknowledged ${r.ack}'
	if got.len > 0 {
		assert r.record() == got, 'step ${step}: the server runs ${r.record()} from ${got}'
	}
	r.inflight = []u8{}
}

// (re)boot: a power-up, a power cut armed in its own journal work two times in three (it fires
// only when the boot has work: a re-home, an erase, a compaction)
fn (mut r SRig) reboot(mut g SRng) {
	match g.next(3) {
		0 { r.boot_cut(1 + g.next(3), 0) }
		1 { r.boot_cut(0, 1) }
		else { r.boot() }
	}
}

// REQ-DIAG-065: a power cut at a random flash program — a record write, an inline compaction's copy,
// the boot's re-home — or at the boot's erase, or a reboot between any two passes, restores the
// record last acknowledged or the one being written, never anything else; a pass that reports the
// state stored leaves the journal holding it exactly, before its answer is pumped, and an
// acknowledged write always survives; the boot's prune keeps the block; and the server starts from
// that record.
// REQ-DIAG-033: an ECUReset's flush leaves exactly the state the server had in the journal.
fn test_power_cuts_anywhere_keep_the_count() {
	mut r := new_srig(1024) // 32 records a sector: compactions and reclaims come round often
	mut g := SRng{
		s: 0x51A5_0001
	}
	mut cuts := 0
	mut resets := 0
	for step in 0 .. 12000 {
		if g.next(6) == 0 {
			r.f.cut_at = r.f.calls + 1 + g.next(3)
			r.f.cut_part = g.next(40)
		}
		match g.next(4) {
			0, 1 { r.key(false) }
			2 { r.key(true) }
			else {
				r.now += u64(g.next(1_500_000))
				r.srv.tick(r.now)
			}
		}
		if r.pass() && !r.f.dead {
			assert r.held() == r.record(), 'step ${step}: acknowledged ${r.ack}, the state is ${r.record()}'
		}
		if !r.f.dead && g.next(20) == 0 {
			// an ECUReset: the flush, then the restart
			if r.quiet_flush() {
				assert r.held() == r.record(), 'step ${step}: the reset flush left ${r.ack}, the state is ${r.record()}'
				resets++
			}
			r.f.cut_at = 0
			r.reboot(mut g)
			r.check_boot(step)
			continue
		}
		if r.f.dead || g.next(15) == 0 {
			if r.f.dead {
				cuts++
			}
			r.f.cut_at = 0
			r.reboot(mut g)
			r.check_boot(step)
		}
	}
	assert cuts > 100 && resets > 50 && r.f.erases > 20 && r.boot_cuts > 20, 'the fuzz exercised too little: ${cuts} cuts, ${r.boot_cuts} in a boot, ${resets} resets, ${r.f.erases} erases'
}

// stream: one wrong-key cycle — security_attempts wrong keys and the lockout's end — each answered
// as a server with no store answers it (0x35, 0x35, 0x36, then 0x37 to a seed during the lockout),
// each pass run at once. The lockout's end changes nothing in the record; a pass that succeeds
// leaves the journal holding the record exactly; a counted key leaves it non-zero. The writes the
// journal accepted.
fn (mut r SRig) stream_cycle(cycle int) int {
	puts := r.puts
	for attempt in 0 .. 4 {
		if attempt < 3 {
			want := if attempt < 2 { u8(0x35) } else { u8(0x36) }
			got := r.key(false)
			assert got == [u8(0x7F), 0x27, want], 'cycle ${cycle} attempt ${attempt}: ${got}'
		} else {
			r.call([u8(0x10), 0x03])
			got := r.call([u8(0x27), 0x01])
			assert got == [u8(0x7F), 0x27, 0x37], 'cycle ${cycle}: the lockout not running: ${got}'
			before := r.record()
			r.now += 1_000_000 // the lockout ends
			r.srv.tick(r.now)
			assert r.record() == before, 'cycle ${cycle}: the lockout ending changed the record'
		}
		if r.pass() {
			assert r.held() == r.record(), 'cycle ${cycle}: acknowledged ${r.ack}, the state is ${r.record()}'
			if attempt < 3 {
				assert r.stored().len > 0 && r.stored()[2..].any(it != 0), 'cycle ${cycle}: a counted key left the journal clear'
			}
		}
	}
	return r.puts - puts
}

// fill: another writer (the fault memory, a coding) puts until the journal refuses — the active
// sector full and its partner waiting for an erase.
fn (mut r SRig) fill() {
	for n in 0 .. 1000 {
		v := [u8(n), 1, 2, 3]!
		if !r.j.put(sp_other, &v[0], 4) {
			return
		}
	}
	assert false, 'the journal never filled'
}

// REQ-DIAG-068: an NM node kept awake (no sleep edge, no erase or compaction at boot) under three
// hours of wrong keys — thousands of them, every lockout waited out. The state is written at most
// security_attempts times however many keys come (the count saturates), so it never fills the
// journal: no erase at run time, and another writer's put is accepted at the end. A power cut after
// any of those keys costs the delay at start-up.
fn test_a_wrong_key_stream_writes_at_most_the_attempts() {
	mut r := &SRig{
		sector: 1024 // 32 records a sector
		now:    1_000_000
		nm:     true
	}
	for b in 0 .. r.f.mem.len {
		r.f.mem[b] = 0xFF
	}
	r.boot()
	r.pass()
	start := r.now
	erases := r.f.erases
	mut cycle := 0
	for r.now < start + 3 * 3600_000_000 {
		r.stream_cycle(cycle)
		cycle++
	}
	assert cycle > 10_000
	assert r.f.erases == erases, '${r.f.erases - erases} erases at run time'
	assert r.puts <= int(uds.default_sa_attempts), '${r.puts} writes in three hours'
	v := [u8(7), 7, 7, 7]
	assert r.j.put(sp_other, &v[0], 4), 'the stream filled the journal for the other writers'
	// a power cut after a wrong key: the start-up runs the delay
	assert r.key(false)[..2] == [u8(0x7F), 0x27]
	r.pass()
	r.boot()
	r.check_boot(cycle)
	r.call([u8(0x10), 0x03])
	assert r.call([u8(0x27), 0x01]) == [u8(0x7F), 0x27, 0x37], 'a power cycle between guesses bought fresh attempts'
}

// sleep_edge: an NM node's bus-sleep edge — the flush choreography with its erase: the sector a
// compaction left behind erased, the state the journal could not take written exactly, and the
// sector that write's compaction left behind erased last (nothing left pending).
fn (mut r SRig) sleep_edge(round int, erases u32) {
	assert r.quiet_flush(), 'round ${round}: the sleep edge failed'
	assert r.f.erases > erases, 'round ${round}: the sleep edge did not erase'
	assert r.j.pending_erase < 0, 'round ${round}: the sleep edge left an erase pending'
	assert r.held() == r.record(), 'round ${round}: the sleep edge left ${r.held()}, the state is ${r.record()}'
}

// after_cut_boot: an NM node's boot after a power cut while another writer's fill held the journal
// full: the boot erases nothing (its sleep edges are its quiet points) and the record last accepted
// is restored — the count the journal could not take is lost with RAM; once the delay it armed is
// over a key is judged as ever and its count held in RAM, the journal refusing it; then a sleep
// edge frees the journal and takes it.
fn (mut r SRig) after_cut_boot(round int, accepted []u8) {
	erases := r.f.erases
	r.boot()
	r.check_boot(round)
	assert r.f.erases == erases, 'round ${round}: the NM boot erased'
	assert r.record() == accepted, 'round ${round}: restored ${r.record()}, last accepted ${accepted}'
	r.now += 1_000_000 // the delay the restored count armed
	r.srv.tick(r.now)
	before := r.srv.sa_since[0]
	assert r.key(false) == [u8(0x7F), 0x27, 0x35], 'round ${round}: a key over a full journal answered otherwise'
	assert r.srv.sa_since[0] == before + 1, 'round ${round}: the key was not counted'
	assert !r.pass(), 'round ${round}: the full journal took the count'
	assert r.held() == accepted && r.f.erases == erases
	r.sleep_edge(round, erases)
}

// REQ-DIAG-067 / REQ-DIAG-065 / REQ-DIAG-062 / REQ-DIAG-033: a node kept awake (an NM node: no sleep
// edge, no erase or compaction at boot) whose journal another writer filled. Nothing erases at run
// time for the state, and a refused write changes no answer: a wrong key is judged and counted, the
// count held in RAM. The flush before an ECUReset frees the journal through its erase and takes the
// count across the reset, and so does a sleep edge; a power cut instead — or one inside the
// ECUReset flush's erase — restores the record last accepted, the count since the fill lost.
fn test_a_journal_another_writer_filled_holds_the_state_in_ram() {
	mut r := &SRig{
		sector: 512 // 16 records a sector
		now:    1_000_000
		nm:     true
	}
	for b in 0 .. r.f.mem.len {
		r.f.mem[b] = 0xFF
	}
	r.boot()
	for round in 0 .. 24 {
		erases := r.f.erases
		assert r.key(false) == [u8(0x7F), 0x27, 0x35], 'round ${round}'
		assert r.pass() && r.held() == r.record(), 'round ${round}: a free journal refused the state'
		accepted := r.record()
		r.fill()
		r.now += sp_retry_us
		r.srv.tick(r.now)
		assert r.key(false) == [u8(0x7F), 0x27, 0x35], 'round ${round}: a refusing journal changed the answer'
		assert !r.pass(), 'round ${round}: the full journal took the count'
		assert r.srv.sa_since[0] == 2 && r.held() == accepted
		assert r.f.erases == erases, 'round ${round}: ${r.f.erases - erases} erases at run time'
		match round % 3 {
			0 {
				// an ECUReset: its flush erases after the answer and takes the count across the
				// reset; a power cut inside that erase in half these rounds
				if round % 6 == 0 {
					r.f.cut_erase = r.f.erases + 1
					assert !r.quiet_flush()
					assert r.f.dead
					r.after_cut_boot(round, accepted)
				} else {
					want := r.record()
					assert r.quiet_flush(), 'round ${round}: the reset flush failed'
					assert r.f.erases > erases && r.j.pending_erase < 0 && r.held() == want
					r.boot()
					r.check_boot(round)
					assert r.record() == want, 'round ${round}: the reset lost the count'
					r.now += 1_000_000 // the delay the count arms
					r.srv.tick(r.now)
				}
			}
			1 {
				r.after_cut_boot(round, accepted) // a power cut
			}
			else {
				r.sleep_edge(round, erases)
			}
		}
		// the journal free again: the third wrong key judged and stored by its own pass (a flush
		// that freed it ended the retry wait), then after the lockout a correct key clearing it
		assert r.srv.sa_since[0] == 2, 'round ${round}: ${r.srv.sa_since[0]} counted'
		assert r.key(false) == [u8(0x7F), 0x27, 0x36], 'round ${round}: the third key answered otherwise'
		assert r.pass() && r.held() == r.record() && r.held()[2] == 3, 'round ${round}: the key not stored: ${r.held()}'
		r.now += 1_000_000 // the lockout it started
		r.srv.tick(r.now)
		assert r.key(true) == [u8(0x67), 0x02], 'round ${round}'
		assert r.pass() && r.held() == r.record() && r.srv.sa_since[0] == 0
	}
}

// REQ-DIAG-065 / REQ-DIAG-067: a correct key's clear the journal refuses — another writer filled it
// after the count was stored — leaves the unlock standing and the clear in RAM; a power cut then
// restores the counted record, costing the delay and granting nothing, and a key after it is judged
// as ever; the next quiet flush takes a clear still pending.
fn test_a_refused_clear_costs_a_delay_never_a_key() {
	for cut in [false, true] {
		mut r := &SRig{
			sector: 512
			now:    1_000_000
			nm:     true
		}
		for b in 0 .. r.f.mem.len {
			r.f.mem[b] = 0xFF
		}
		r.boot()
		assert r.key(false) == [u8(0x7F), 0x27, 0x35]
		assert r.pass()
		counted := r.held()
		assert counted[2] == 1, 'the wrong key was not stored: ${counted}'
		r.fill()
		assert r.key(true) == [u8(0x67), 0x02]
		assert !r.pass(), 'a full journal took the clear'
		assert r.srv.sa_since[0] == 0 && r.held() == counted
		erases := r.f.erases
		if !cut {
			r.sleep_edge(0, erases) // the flush takes the clear
			assert r.held()[2] == 0
			continue
		}
		r.boot()
		r.check_boot(0)
		assert r.srv.sa_since[0] == 1
		r.call([u8(0x10), 0x03])
		assert r.call([u8(0x27), 0x01]) == [u8(0x7F), 0x27, 0x37], 'a refused clear granted a key'
		r.now += 1_000_000
		r.srv.tick(r.now)
		assert r.key(true) == [u8(0x67), 0x02], 'the key after the delay was not judged'
		assert !r.pass(), 'the full journal took the clear'
		r.sleep_edge(0, erases)
		assert r.srv.sa_since[0] == 0 && r.held()[2] == 0
	}
}
