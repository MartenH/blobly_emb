module fault

import boot
import nvm
import comm.uds

// @verifies REQ-DIAG-016
// (the fault memory persisted in the NvM journal: what survives a reset and a power loss, the
//  operation cycle power interrupted, bounded writes, a durable 0x14, an update that reorders the
//  faults, and power cuts anywhere in a write, displacement included.)

const pf_sector = u32(1024) // 32 records a sector: compaction comes round often

// PFlash is RAM flash with a power cut: the program call numbered `cut_at` writes part of its
// record and the power is gone — every later program and erase fails until `revive`.
struct PFlash {
mut:
	mem      [2048]u8
	calls    u32
	cut_at   u32 // 0 = no cut armed
	cut_part u32
	dead     bool
	refuse   bool // every program fails, nothing written (a store that refuses)
}

fn pf_off(addr u32) u32 {
	return addr
}

fn pf_erase(ctx voidptr, addr u32, size u32) bool {
	mut f := unsafe { &PFlash(ctx) }
	if f.dead {
		return false
	}
	for i in 0 .. size {
		f.mem[pf_off(addr) + i] = 0xFF
	}
	return true
}

fn pf_program(ctx voidptr, addr u32, data &u8, len u32) bool {
	mut f := unsafe { &PFlash(ctx) }
	if f.dead || f.refuse {
		return false
	}
	f.calls++
	mut n := len
	if f.cut_at != 0 && f.calls == f.cut_at {
		n = f.cut_part % (len + 1)
		f.dead = true
	}
	for i in 0 .. n {
		f.mem[pf_off(addr) + i] = unsafe { data[i] }
	}
	return !f.dead
}

fn pf_read(ctx voidptr, addr u32, out &u8, len u32) bool {
	f := unsafe { &PFlash(ctx) }
	for i in 0 .. len {
		unsafe {
			out[i] = f.mem[pf_off(addr) + i]
		}
	}
	return true
}

fn pf_put(ctx voidptr, id u16, data &u8, len u16) bool {
	mut r := unsafe { &Rig(ctx) }
	if r.refuse_id != 0 && id == r.refuse_id {
		return false
	}
	// THE INVARIANT (persist.v), checked at the write itself: no block the last COMMITTED image
	// claims is ever written or tombstoned
	if id != r.m.store.id {
		mut img := [max_image]u8{}
		n := int(r.j.get(r.m.store.id, &img[0], u16(max_image)))
		for o := 2; o + image_rec <= n; o += image_rec {
			f := img[o + 3]
			if f & img_snapshot == 0 {
				continue
			}
			k := int(img[o + 2]) // the rig's DTCs are 0xC1000k
			claimed := if f & img_block_b != 0 { u16(0x1100 + k) } else { u16(0x1000 + k) }
			assert id != claimed, 'block 0x${id.hex()} written (${len} B) while the committed image claims it'
		}
	}
	// ... and its other half: an image never claims a block that does not hold a snapshot
	if id == r.m.store.id {
		for o := 2; o + image_rec <= int(len); o += image_rec {
			f := unsafe { data[o + 3] }
			if f & img_snapshot == 0 {
				continue
			}
			k := int(unsafe { data[o + 2] })
			claimed := if f & img_block_b != 0 { u16(0x1100 + k) } else { u16(0x1000 + k) }
			mut b := [4]u8{}
			assert r.j.get(claimed, &b[0], 4) > 1, 'an image claims block 0x${claimed.hex()}, which holds no snapshot'
		}
	}
	r.puts++
	if id == r.m.store.id {
		r.image_puts++
	}
	return r.j.put(id, data, len)
}

fn pf_get(ctx voidptr, id u16, out &u8, cap u16) u16 {
	r := unsafe { &Rig(ctx) }
	return r.j.get(id, out, cap)
}

// Rig is one ECU: the flash outlives a reboot, the journal and the memory do not.
@[heap]
struct Rig {
mut:
	f          PFlash
	refuse_id  u16 // the store refuses writes to this block (0 = none)
	j          nvm.Journal
	m          Memory
	srv        uds.Server
	d          [4]Debounce
	puts       int
	image_puts int
	cap        int
	swapped    bool // an update swapped the snapshot's DID sizes (F1A0 18 B, F190 4 B): same length
	order      [4]int // which configured slot carries DTC k (an update may reorder)
	n          int
}

const rig_dtcs = [u32(0xC10000), 0xC10001, 0xC10002, 0xC10003]

fn new_rig(cap int) &Rig {
	mut r := &Rig{
		cap: cap
		n:   4
	}
	for k in 0 .. 4 {
		r.order[k] = k
	}
	for b in 0 .. r.f.mem.len {
		r.f.mem[b] = 0xFF
	}
	r.reboot()
	return r
}

// reboot: the journal mounted and its pending erase done (the boot quiet point of a node without
// NM), the memory configured, restored, and its power cycle begun — what the generated comm thread
// does at start. Slots 0..2 keep a snapshot (F1A0, 4 B + F190, 18 B: a chained block); slot 3 none.
fn (mut r Rig) reboot() {
	r.restart(true)
}

// restart: `power_cycle` begins the cycle at once ([fault_memory] cycle = "power"); without it the
// node waits for NM to wake it.
fn (mut r Rig) restart(power_cycle bool) {
	r.f.dead = false
	r.f.cut_at = 0
	r.j = nvm.Journal{}
	r.j.ops = boot.FlashOps{
		ctx:     &r.f
		erase:   pf_erase
		program: pf_program
		read:    pf_read
	}
	r.j.cfg = nvm.SectorCfg{
		a_addr: 0
		b_addr: pf_sector
		size:   pf_sector
	}
	assert r.j.mount()
	r.j.erase_pending()
	r.m = Memory{}
	for k in 0 .. r.n {
		i := r.order[k]
		mut s := &r.m.slots[i]
		s.dtc = rig_dtcs[k]
		s.confirm = 1
		s.aging = 2
		s.priority = u8(100 + k)
		if k < 3 {
			s.freeze[0] = 0xF1A0
			s.freeze_len[0] = if r.swapped { u8(18) } else { 4 }
			s.freeze[1] = 0xF190
			s.freeze_len[1] = if r.swapped { u8(4) } else { 18 }
			s.nfreeze = 2
			s.snap_id = u16(0x1000 + k)
			s.snap_id_b = u16(0x1100 + k)
		}
	}
	r.m.n = r.n
	r.m.cap = r.cap
	r.m.init()
	r.m.store = Store{
		ctx:      r
		put:      pf_put
		get:      pf_get
		id:       0x0F00
		retry_us: 1000
	}
	r.m.restore()
	if power_cycle {
		r.m.cycle_start() // cycle = "power"
	}
	r.srv = uds.Server{}
	r.srv.init(256)
	r.srv.faults = r.m.uds_ops()
	r.srv.dids[0] = uds.Did{
		id: 0xF1A0
	}
	r.srv.dids[1] = uds.Did{
		id:  0xF190
		len: 18
	}
	r.srv.ndid = 2
	// where the swapped schema looks for its second DID id, the old record holds 0xF190: reading
	// the record's content alone would take the old bytes for the new schema
	r.srv.dids[1].data[12] = 0xF1
	r.srv.dids[1].data[13] = 0x90
	for k in 0 .. 4 {
		r.d[k] = Debounce{
			fail_thr: 1
			pass_thr: 1
			jump:     true
		}
	}
}

// pass: one owner pass with result `res` for DTC k (none for -1) — apply, step, consume, capture,
// persist — at time `now`; the speed DID reads `speed`.
fn (mut r Rig) pass(k int, res TestResult, speed u32, now u64) bool {
	r.srv.dids[0].len = 4
	r.srv.dids[0].data[3] = u8(speed)
	r.srv.dids[0].data[2] = u8(speed >> 8)
	if k >= 0 {
		i := r.order[k]
		r.d[k].apply(r.m.control_gen(i), r.m.control_held(i))
		r.d[k].step(res, now, true)
		r.m.consume(i, r.d[k].rep)
	}
	if r.m.capture_due() {
		r.m.capture(&r.srv)
	}
	return r.m.persist(now, false)
}

fn (mut r Rig) req(q []u8) []u8 {
	mut resp := [256]u8{}
	n := r.srv.handle(&q[0], q.len, &resp[0])
	mut out := []u8{}
	for i in 0 .. n {
		out << resp[i]
	}
	return out
}

fn (r &Rig) slot(k int) Slot {
	return r.m.slots[r.order[k]]
}

// A confirmed DTC survives a reset with what ISO 14229-1 keeps across power-up: pending,
// confirmed, testFailedSinceLastClear, its counters and its snapshot; testFailed and the cycle
// bits restart. Nothing was flushed: the immediate writes alone carry it (a power cut).
fn test_a_confirmed_dtc_and_its_snapshot_survive_a_power_cut() {
	mut r := new_rig(2)
	r.pass(1, .passed, 0, 1)
	r.pass(1, .failed, 77, 2)
	snap := r.req([u8(0x19), 0x04, 0xC1, 0x00, 0x01, 0x01])
	assert snap[5] == 0x2F
	r.reboot()
	s := r.slot(1)
	assert s.status == pending | confirmed | failed_since_clear | not_completed_this_cycle, 'status 0x${s.status.hex()}'
	assert s.occurrence == 1 && s.failed_cycles == 1
	after := r.req([u8(0x19), 0x04, 0xC1, 0x00, 0x01, 0x01])
	assert after[6..] == snap[6..], 'the snapshot changed across the reset'
	assert after[5] == 0x6C
	assert r.req([u8(0x19), 0x03]) == [u8(0x59), 0x03, 0xC1, 0x00, 0x01, 0x01]
	assert r.req([u8(0x19), 0x06, 0xC1, 0x00, 0x01, 0xFF]) == [u8(0x59), 0x06, 0xC1, 0x00, 0x01,
		0x6C, 0x01, 0x00, 0x01, 0x02, 0x00, 0x03, 0x01]
	// a DTC never tested keeps testNotCompletedSinceLastClear; one tested and passed does not
	assert r.slot(0).status == status_cleared
	r.pass(0, .passed, 0, 3)
	r.reboot()
	assert r.slot(0).status == not_completed_this_cycle
}

// The cycle power interrupted is ended at restore with what it collected: a DTC tested and not
// failed in it is no longer pending, and a confirmed one ages — across power cycles exactly as
// across an orderly cycle end.
fn test_the_interrupted_cycle_ends_at_restore() {
	mut r := new_rig(2)
	r.pass(0, .failed, 1, 1)
	r.reboot() // cycle 1 ended: it failed, so it stays pending
	assert r.slot(0).status & (pending | confirmed) == pending | confirmed
	r.pass(0, .passed, 1, 2)
	r.reboot() // cycle 2 passed: no longer pending, aging 1 of 2
	assert r.slot(0).status & (pending | confirmed) == confirmed
	assert r.slot(0).aging_count == 1 && r.slot(0).entry != 0
	r.reboot() // cycle 3 never tested: nothing moves
	assert r.slot(0).aging_count == 1
	r.pass(0, .passed, 1, 3)
	r.restart(false) // cycle 4 passed: aged out — ended at RESTORE, before any wake begins the next
	assert !r.m.cycle_active
	r.m.cycle_start()
	assert r.slot(0).status & (pending | confirmed) == 0 && r.slot(0).entry == 0
	r.pass(-1, .not_tested, 0, 4)
	mut b := [4]u8{}
	assert r.j.get(0x1000, &b[0], 4) == 1, 'the freed snapshot block was not tombstoned'
	assert r.slot(0).status & failed_since_clear != 0
}

// Writes are bounded by status changes, never per debounce step: a thousand passing dispatches
// write the image once (the first completed test), and an intermittent fault writes it once more
// (the first failure, with its snapshot) however often it occurs — its later occurrences are
// deferred to the next image write or flush.
fn test_writes_are_bounded_by_status_changes() {
	mut r := new_rig(2)
	r.puts = 0
	r.image_puts = 0
	for t in 0 .. 1000 {
		r.pass(2, .passed, 0, u64(10 + t))
	}
	assert r.image_puts == 1 && r.puts == 1, '${r.puts} writes for a steadily passing test'
	for t in 0 .. 1000 {
		r.pass(2, if t % 3 == 0 { TestResult.failed } else { .passed }, u32(t), u64(2000 + t))
	}
	assert r.slot(2).occurrence == 334
	assert r.image_puts == 2 && r.puts == 3, '${r.puts} writes (${r.image_puts} images) for an intermittent fault'
	// a power cut now loses the deferred occurrences, never more and never doubled
	r.reboot()
	assert r.slot(2).occurrence == 1
}

// A flush (a sleep edge, an ECUReset) makes the deferred counters durable.
fn test_a_flush_makes_deferred_occurrences_durable() {
	mut r := new_rig(2)
	for t in 0 .. 30 {
		r.pass(2, if t % 2 == 0 { TestResult.failed } else { .passed }, 1, u64(t + 1))
	}
	assert r.slot(2).occurrence == 15
	assert !r.m.persist(100, false), 'deferred counters reported as durable'
	assert r.m.persist(100, true)
	r.reboot()
	assert r.slot(2).occurrence == 15
}

// 0x14 is durable before it is acknowledged: a store that refuses the cleared image gets 0x72 and
// changes nothing, live or stored; the next clear that the store takes clears.
fn test_a_refused_clear_answers_0x72_and_changes_nothing() {
	mut r := new_rig(2)
	r.pass(0, .failed, 5, 1)
	before := r.slot(0)
	r.f.refuse = true
	assert r.req([u8(0x14), 0xFF, 0xFF, 0xFF]) == [u8(0x7F), 0x14, 0x72]
	assert r.slot(0).status == before.status && r.slot(0).entry != 0 && r.m.control_gen(0) == before.gen
	r.f.refuse = false
	r.reboot()
	assert r.slot(0).status & confirmed != 0, 'a refused clear reached the store'
	assert r.req([u8(0x14), 0xC1, 0x00, 0x00]) == [u8(0x54)]
	assert r.slot(0).status == status_cleared
	r.reboot()
	assert r.slot(0).status == status_cleared, 'an acknowledged clear was not durable'
	r.pass(-1, .not_tested, 0, 2)
	mut b := [4]u8{}
	assert r.j.get(0x1000, &b[0], 4) == 1, 'the cleared snapshot block was not tombstoned'
}

// A refused automatic write stays outstanding and is retried — no sooner than retry_us, so a
// store that keeps refusing is not hammered every pass.
fn test_a_refused_write_is_retried_after_the_pause() {
	mut r := new_rig(2)
	r.f.refuse = true
	r.pass(1, .failed, 1, 1000)
	calls := r.puts
	r.pass(-1, .not_tested, 0, 1500)
	assert r.puts == calls, 'retried inside the pause'
	r.f.refuse = false
	r.pass(-1, .not_tested, 0, 2000)
	assert r.puts > calls
	r.reboot()
	assert r.slot(1).status & confirmed != 0 && r.slot(1).entry != 0
}

// A firmware update that reorders, removes and adds faults restores each by its DTC NUMBER.
fn test_an_update_restores_each_dtc_by_number() {
	mut r := new_rig(2)
	r.pass(0, .failed, 1, 1)
	r.pass(3, .failed, 1, 2)
	r.m.persist(3, true)
	r.order = [3, 1, 0, 2]! // DTC k now lives in slot order[k]
	r.reboot()
	assert r.slot(0).status & confirmed != 0 && r.slot(0).entry != 0
	assert r.slot(3).status & confirmed != 0
	assert r.slot(1).status == status_cleared && r.slot(2).status == status_cleared
	assert r.req([u8(0x19), 0x03]) == [u8(0x59), 0x03, 0xC1, 0x00, 0x00, 0x01]
	r.n = 3 // DTC 3 removed: the others are unaffected
	r.order = [0, 1, 2, 3]!
	r.reboot()
	assert r.slot(0).status & confirmed != 0 && r.m.n == 3
}

// An update that lowers `cap` keeps the most important snapshots, the newest among equals.
fn test_a_lower_cap_keeps_the_most_important_snapshots() {
	mut r := new_rig(3)
	r.pass(2, .failed, 1, 1) // priority 102, oldest
	r.pass(1, .failed, 1, 2) // 101
	r.pass(0, .failed, 1, 3) // 100: the most important
	r.cap = 1
	r.reboot()
	assert r.slot(0).entry != 0 && r.slot(1).entry == 0 && r.slot(2).entry == 0
	r.pass(-1, .not_tested, 0, 4)
	mut b := [4]u8{}
	assert r.j.get(0x1001, &b[0], 4) == 1 && r.j.get(0x1002, &b[0], 4) == 1
}

// Power cuts anywhere: a random life of failures, passes, clears, cycle ends and displacements,
// with the power cut at a random flash program inside a write (snapshots, image, tombstones, a
// clear, a compaction). Each step runs first on a SHADOW of the ECU that keeps its power, which
// says what the step writes; then on the ECU, cut. After a cut the store holds EXACTLY the image it
// held before the step or the one the step was writing — never a mixture, so no occurrence is
// doubled or invented and no status bit comes from neither — and every snapshot the image claims
// is there and is exactly the one captured for it: a displacement cut half-way loses neither entry.
fn test_power_cuts_anywhere_leave_one_coherent_memory() {
	mut rng := u32(0x2545F491)
	mut cuts := 0
	mut displaced := 0
	mut mid_image := 0
	mut refusals := 0
	mut held := 0
	mut flips := 0
	for run in 0 .. 40 {
		mut r := new_rig(2)
		mut captured := map[string][]u8{} // dtc:stamp -> the record captured
		mut schema_of := map[string]bool{} // dtc:record -> captured under the swapped schema
		mut now := u64(1)
		for step in 0 .. 300 {
			rng ^= rng << 13
			rng ^= rng >> 17
			rng ^= rng << 5
			now += 7
			ctx := 'run ${run} step ${step}'
			op := rng % 100
			if (rng >> 20) % 61 == 0 {
				// a firmware update that changes the snapshot's schema but not its length: no
				// snapshot of the old schema comes back as one of the new
				r.swapped = !r.swapped
				r.reboot()
				for k in 0 .. r.m.cap {
					e := r.m.entries[k]
					if e.used {
						rec := '${r.m.slots[e.slot].dtc}:${e.data[..e.len].hex()}'
						assert schema_of[rec] == r.swapped, '${ctx}: a snapshot of the old schema was restored under the new one (${rec})'
					}
				}
				flips++
				r.m.persist(now, true) // the first pass after the update: claims of the old schema dropped
				continue
			}
			old := stored_image(r)
			mut sh := shadow(r)
			do_step(mut sh, op, rng, step, now)
			new := stored_image(sh)
			programs := sh.f.calls - r.f.calls // what the step programs, from the shadow
			// a step that displaces is the one a refusal of the NEW snapshot must not cost both sides of
			displacing := sh.m.displaced != r.m.displaced
			refusing := programs > 0 && (rng % 5 == 1 || (displacing && rng % 2 == 0))
			if refusing {
				// a REFUSAL, not a cut: the store says no to one snapshot block (the new one, when the
				// step displaces), or to every write (no headroom, a program failure); the ECU runs on
				refusals++
				if displacing {
					held++
					mut newest := 0
					for k in 1 .. sh.m.cap {
						if sh.m.entries[k].stamp > sh.m.entries[newest].stamp {
							newest = k
						}
					}
					r.refuse_id = sh.m.slots[sh.m.entries[newest].slot].snap_id
				} else if (rng >> 9) % 3 == 0 {
					r.refuse_id = u16(0x1000 + (rng >> 11) % 3) + if (rng >> 13) & 1 == 0 { u16(0) } else { u16(0x100) }
				} else if (rng >> 9) % 3 == 1 {
					r.refuse_id = r.m.store.id // the image alone: its snapshots and tombstones go through
				} else {
					r.f.refuse = true
				}
			} else if programs > 0 && rng % 3 == 0 {
				r.f.cut_at = r.f.calls + 1 + (rng >> 8) % programs
				r.f.cut_part = (rng >> 16) % 33
			}
			pre := r.m.displaced
			do_step(mut r, op, rng, step, now)
			if r.m.displaced != pre {
				displaced++
			}
			r.refuse_id = 0
			r.f.refuse = false
			// the journal never holds more than the generator budgets: the image, EVERY snapshot
			// block whole, the marker (gen_nvm.v derive_fault_nvm)
			budget := nvm.records_for(u16(2 + r.m.n * image_rec)) + 6 * nvm.records_for(u16(snap_hdr +
				r.m.snap_len(0))) + 1
			assert r.j.live_records() <= budget, '${ctx}: ${r.j.live_records()} live records, the budget is ${budget}'
			for k in 0 .. r.m.cap {
				e := r.m.entries[k]
				if e.used {
					key := '${r.m.slots[e.slot].dtc}:${e.stamp}'
					schema_of['${r.m.slots[e.slot].dtc}:${e.data[..e.len].hex()}'] = r.swapped // RAM holds the schema in force
					captured[key] = e.data[..e.len].clone()
				}
			}
			if !r.f.dead {
				r.f.cut_at = 0
				after := stored_image(r)
				if !refusing {
					assert after == new, '${ctx}: the shadow and the ECU wrote different images'
					continue
				}
				// refused: a snapshot the store claimed may stop being claimed only when the DTC no
				// longer holds a failure (healed, aged, cleared) or its replacement is claimed in the
				// same image — never both sides of a displacement gone
				lost := claimed(old).filter(it !in claimed(after))
				gained := claimed(after).filter(it !in claimed(old))
				for dtc in lost {
					i := r.m.slot_of(dtc)
					freed := r.m.slots[i].status & (pending | confirmed) == 0
					assert freed || gained.len > 0, '${ctx}: DTC ${dtc:06X} lost its stored snapshot to a refused write, and nothing replaced it'
				}
				continue
			}
			cuts++
			if old != new {
				mid_image++
			}
			r.reboot()
			got := stored_image(r)
			assert got == old || got == new, '${ctx}: the store holds ${got}\n  before ${old}\n  writing ${new}'
			for i in 0 .. r.m.n {
				if got.len == 0 || got[2 + i * image_rec + 3] & img_snapshot == 0 {
					continue
				}
				// claimed: the block is there, whole, this DTC's, and exactly what was captured
				mut blk := [max_block]u8{}
				bid := if got[2 + i * image_rec + 3] & img_block_b != 0 { r.m.slots[i].snap_id_b } else { r.m.slots[i].snap_id }
				n := int(r.j.get(bid, &blk[0], u16(max_block)))
				assert n == snap_hdr + r.m.snap_len(i), '${ctx}: slot ${i} claims a snapshot the store does not hold (${n} B)'
				dtc := u32(blk[0]) << 16 | u32(blk[1]) << 8 | u32(blk[2])
				stamp := u32(blk[3]) << 24 | u32(blk[4]) << 16 | u32(blk[5]) << 8 | u32(blk[6])
				key := '${dtc}:${stamp}'
				assert dtc == r.m.slots[i].dtc && key in captured
					&& captured[key] == blk[snap_hdr..n], '${ctx}: slot ${i} claims a snapshot that is not the one captured'
			}
		}
	}
	println('persistence fuzz: ${cuts} power cuts (${mid_image} of them in a step that changed the image), ${refusals} refusals (${held} of the new snapshot of a displacement), ${displaced} displacements, ${flips} schema changes')
	assert cuts > 300 && mid_image > 50 && displaced > 20 && refusals > 300 && held > 10 && flips > 20
}

// claimed: the DTCs a status image claims a stored snapshot for.
fn claimed(img []u8) []u32 {
	mut out := []u32{}
	for o := 2; o + image_rec <= img.len; o += image_rec {
		if img[o + 3] & img_snapshot != 0 {
			out << u32(img[o]) << 16 | u32(img[o + 1]) << 8 | u32(img[o + 2])
		}
	}
	return out
}

// do_step: one random action — a result for a DTC (most of them), a clear, a flush, or a power
// cycle's end and the next's start.
fn do_step(mut r Rig, op u32, rng u32, step int, now u64) {
	if op < 80 {
		k := int((rng >> 4) % 4)
		res := if (rng >> 7) % 3 == 0 { TestResult.failed } else { TestResult.passed }
		r.srv.dids[1].data[0] = u8(step)
		r.pass(k, res, u32(rng >> 12), now)
	} else if op < 86 {
		group := if (rng >> 4) & 1 == 0 { u32(0xFFFFFF) } else { rig_dtcs[(rng >> 5) % 4] }
		r.m.clear(group)
	} else if op < 92 {
		r.m.persist(now, true)
	} else {
		r.m.cycle_end()
		r.m.cycle_start()
		r.m.persist(now, false)
	}
}

// shadow: a copy of the ECU, flash included, wired to itself.
fn shadow(r &Rig) &Rig {
	mut sh := &Rig{}
	unsafe {
		*sh = *r
	}
	sh.j.ops.ctx = &sh.f
	sh.m.store.ctx = sh
	sh.srv.faults = sh.m.uds_ops()
	return sh
}

// stored_image: the status image the store holds, as a fresh mount reads it.
fn stored_image(r &Rig) []u8 {
	mut j := nvm.Journal{}
	j.ops = r.j.ops
	j.cfg = r.j.cfg
	if !j.mount() {
		return []u8{}
	}
	mut b := [max_image]u8{}
	n := j.get(0x0F00, &b[0], u16(max_image))
	return b[..n].clone()
}

fn test_the_scratch_holds_either() {
	assert max_block >= max_image && max_block >= snap_hdr + max_snapshot
	assert max_image <= int(nvm.chain_data_max) && snap_hdr + max_snapshot <= int(nvm.chain_data_max)
}

// A tombstone waits for the image that stops claiming its snapshot: while the store refuses that
// image, the snapshot block is left alone — a power cut then restores the claim AND its snapshot.
fn test_a_snapshot_is_not_tombstoned_while_an_image_still_claims_it() {
	mut r := new_rig(2)
	r.pass(0, .failed, 9, 1)
	r.refuse_id = r.m.store.id
	r.m.free_entry(0) // what a displacement or an aging does to RAM
	r.pass(-1, .not_tested, 0, 2000)
	mut b := [max_block]u8{}
	assert int(r.j.get(0x1000, &b[0], u16(max_block))) > 1, 'tombstoned while the durable image claims it'
	r.refuse_id = 0
	r.reboot()
	assert r.slot(0).entry != 0, 'the claimed snapshot was lost'
}

// The counters keep their full width across a reset, and a snapshot block that is not this DTC's
// (an update whose id now names another snapshot) is never served as its snapshot.
fn test_counters_keep_their_width_and_a_foreign_snapshot_is_refused() {
	mut r := new_rig(2)
	r.pass(1, .failed, 1, 1)
	r.m.slots[r.order[1]].occurrence = 0x1234
	assert r.m.persist(2, true)
	r.reboot()
	assert r.slot(1).occurrence == 0x1234
	// the block under DTC 1's snapshot id now holds DTC 0's record
	mut b := [max_block]u8{}
	n := r.j.get(0x1001, &b[0], u16(max_block))
	b[2] = 0x00
	assert r.j.put(0x1001, &b[0], n)
	r.reboot()
	assert r.slot(1).entry == 0 && r.slot(1).status & confirmed != 0
	assert r.req([u8(0x19), 0x03]) == [u8(0x59), 0x03]
}

// A refused snapshot that displaced nothing holds nothing back: the image is written without
// claiming it, and a 0x14 of another DTC is answered — the hold is only for a displacement, whose
// victim the durable image must keep claiming until its replacement is in.
fn test_only_a_displacing_snapshot_holds_the_image() {
	mut r := new_rig(2)
	r.refuse_id = 0x1001
	r.pass(1, .failed, 1, 1) // its snapshot is refused; nothing was displaced
	r.pass(0, .failed, 1, 2)
	assert r.req([u8(0x14), 0xC1, 0x00, 0x00]) == [u8(0x54)]
	r.refuse_id = 0
	r.reboot()
	assert r.slot(1).status & confirmed != 0 && r.slot(0).status == status_cleared
}

// A pinned snapshot id kept across an update that changed the snapshot restores nothing rather
// than the old record under the new schema.
fn test_a_kept_pin_does_not_restore_another_schema() {
	mut r := new_rig(2)
	r.pass(0, .failed, 7, 1)
	r.reboot()
	assert r.slot(0).entry != 0
	// the same block id, the same sizes, another first DID
	mut m := Memory{}
	for i in 0 .. r.m.n {
		m.slots[i] = r.m.slots[i]
	}
	m.slots[0].freeze[0] = 0xF1A1
	m.n = r.m.n
	m.cap = r.m.cap
	m.init()
	m.store = r.m.store
	m.restore()
	assert m.slots[0].entry == 0 && m.slots[0].status & confirmed != 0
}

// Power lost with DTC setting off (0x85): the interrupted cycle ends as it would have then —
// changing nothing — and setting is on again after the power-up.
fn test_a_cycle_interrupted_with_setting_off_ends_changing_nothing() {
	mut r := new_rig(2)
	r.pass(0, .failed, 1, 1)
	r.reboot() // cycle 1 failed: pending
	r.pass(0, .passed, 1, 2) // cycle 2 tested and passed ...
	r.m.set_setting(false) // ... and then DTC setting off, and the power goes
	r.m.persist(3, false)
	before := r.slot(0).status & persisted_bits
	r.reboot()
	assert r.slot(0).status & persisted_bits == before, 'the suppressed cycle end cleared pending or aged'
	assert r.slot(0).aging_count == 0 && r.slot(0).entry != 0
	assert !r.m.setting_off
}

// A refused 0x14 stays visible to the owner through the next persist, so a node without NM can
// make room (its runtime erase) instead of answering 0x72 until the next boot.
fn test_a_refused_clear_reaches_the_owner() {
	mut r := new_rig(2)
	r.pass(0, .failed, 1, 1)
	r.f.refuse = true
	assert r.req([u8(0x14), 0xFF, 0xFF, 0xFF]) == [u8(0x7F), 0x14, 0x72]
	r.f.refuse = false
	r.m.persist(2, false)
	assert r.m.refused, 'the refused clear was forgotten by the pass that followed it'
	r.m.persist(3, false)
	assert !r.m.refused
}

// ... also inside a refusal's retry pause, when the pass itself writes nothing.
fn test_a_refused_clear_reaches_the_owner_inside_the_retry_pause() {
	mut r := new_rig(2)
	r.f.refuse = true
	r.pass(0, .failed, 1, 1000) // refused: the next write waits until 2000
	r.f.refuse = false
	assert r.m.persist(1100, true) && !r.m.refused // a flush gets through (a sleep edge, a 0x11)
	r.f.refuse = true
	assert r.req([u8(0x14), 0xFF, 0xFF, 0xFF]) == [u8(0x7F), 0x14, 0x72]
	r.m.persist(1500, false)
	assert r.m.refused, 'a refused clear stayed invisible through the retry pause'
	r.f.refuse = false
}

// Round 3's two scenarios, each with the store refusing the image at the worst moment. A DTC
// displaced and then reacquired writes its OTHER block — the committed image still claims the old
// one — and an update that lowers `entries` leaves the dropped snapshot claimed (and untouched)
// until an image that drops it commits. The invariant oracle in pf_put fails at the offending write.
fn test_reacquire_after_displacement_writes_the_other_block() {
	mut r := new_rig(1)
	r.m.slots[r.order[0]].priority = 50 // equals: either may displace the other
	r.m.slots[r.order[1]].priority = 50
	r.pass(0, .failed, 1, 1) // DTC 0 takes the one entry: block A, committed
	r.m.cycle_end()
	r.m.cycle_start()
	r.pass(0, .passed, 1, 2)
	r.refuse_id = r.m.store.id // every image refused from here: block A stays committed to DTC 0
	r.pass(1, .failed, 2, 3) // DTC 1 displaces DTC 0 (passive, from an earlier cycle)
	assert r.slot(0).entry == 0 && r.slot(1).entry != 0 && r.slot(0).claim == 1
	r.m.cycle_end()
	r.m.cycle_start()
	r.pass(1, .passed, 2, 40000)
	r.pass(0, .failed, 9, 50000) // DTC 0 reacquires the entry, displacing DTC 1
	assert r.slot(0).entry != 0, 'DTC 0 did not reacquire'
	assert r.m.entries[r.slot(0).entry - 1].blk == 2, 'the reacquired snapshot went to the block the committed image claims'
	assert r.m.entries[r.slot(0).entry - 1].durable
	r.refuse_id = 0
	r.reboot() // nothing new committed: the committed image and its block A come back intact
	assert r.slot(0).entry != 0 && r.m.entries[r.slot(0).entry - 1].blk == 1
}

fn test_lowered_entries_leave_the_dropped_snapshot_claimed() {
	mut r := new_rig(2)
	r.pass(1, .failed, 1, 1)
	r.pass(0, .failed, 2, 2) // two snapshots committed
	r.cap = 1
	r.refuse_id = r.m.store.id
	r.reboot() // the update drops one; the image that would release it is refused
	r.pass(-1, .not_tested, 0, 3)
	mut blk := [max_block]u8{}
	assert int(r.j.get(0x1001, &blk[0], u16(max_block))) > 1, 'the dropped snapshot was tombstoned under a committed claim'
	r.refuse_id = 0
	r.pass(-1, .not_tested, 0, 2000) // now an image without it commits, and then it goes
	r.pass(-1, .not_tested, 0, 3000)
	assert r.j.get(0x1001, &blk[0], u16(max_block)) == 1
}
