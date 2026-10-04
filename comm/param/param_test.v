module param

import boot
import nvm
import comm.uds

// @verifies REQ-DIAG-017
// (parameters: a coded value durable before it is acknowledged, validated at 0x2E and again at
//  restore, applied at the next dispatch or the next start, read back by 0x22, never written twice
//  for one value, and never another schema's bytes — under power cuts anywhere in a write.)

const pf_sector = u32(1024) // 32 records a sector: compaction comes round often

// PFlash is RAM flash with a power cut: the program call numbered `cut_at` writes part of its
// record and the power is gone — every later program and erase fails until the next boot.
struct PFlash {
mut:
	mem      [2048]u8
	calls    u32
	cut_at   u32 // 0 = no cut armed
	cut_part u32
	dead     bool
	refuse   bool // every program fails, nothing written (a store that refuses)
}

fn pf_erase(ctx voidptr, addr u32, size u32) bool {
	mut f := unsafe { &PFlash(ctx) }
	if f.dead {
		return false
	}
	for i in 0 .. size {
		f.mem[addr + i] = 0xFF
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
		f.mem[addr + i] = unsafe { data[i] }
	}
	return !f.dead
}

fn pf_read(ctx voidptr, addr u32, out &u8, len u32) bool {
	f := unsafe { &PFlash(ctx) }
	for i in 0 .. len {
		unsafe {
			out[i] = f.mem[addr + i]
		}
	}
	return true
}

fn st_put(ctx voidptr, id u16, data &u8, len u16) bool {
	mut r := unsafe { &Rig(ctx) }
	r.puts++
	return r.j.put(id, data, len)
}

fn st_get(ctx voidptr, id u16, out &u8, cap u16) u16 {
	r := unsafe { &Rig(ctx) }
	return r.j.get(id, out, cap)
}

fn st_publish(ctx voidptr, i int, a u32, b u32) {
	mut r := unsafe { &Rig(ctx) }
	r.cell_a[i] = a
	r.cell_b[i] = b
	r.pubs[i]++
}

// The parameters of the rig, by index.
const steer = 0 // SteerLimit { deg u16 } 0..360, default 360, next dispatch — DID 0x0110
const trailer = 1 // TrailerFitted { fitted bool }, default false, at the next start — DID 0x0111
const offset = 2 // Offset { x i16 -100..100, y i8 -10..10 }, default (0, 0), next dispatch — 0x0112
const status_did = u16(0x0120)

// Schema is what one firmware build says about the parameters: the update tests change it.
struct Schema {
mut:
	steer_max   i64 = 360
	steer_def   i64 = 360
	steer_fp    u16 = 0x5151 // the layout's fingerprint; another layout under a pinned id: another fp
	trailer_id  u16 = 0x2002
	offset_x_lo i64 = -100
}

// Rig is one ECU: the flash outlives a reboot; the journal, the table and the server do not.
@[heap]
struct Rig {
mut:
	f      PFlash
	j      nvm.Journal
	ps     Params
	srv    uds.Server
	sa     uds.ReferenceSecurity
	sch    Schema
	puts   int
	cell_a [max_params]u32
	cell_b [max_params]u32
	pubs   [max_params]int
}

fn new_rig() &Rig {
	mut r := &Rig{}
	for b in 0 .. r.f.mem.len {
		r.f.mem[b] = 0xFF
	}
	r.reboot()
	return r
}

// reboot: what the generated image does at start — the journal mounted and its pending erase done
// (the boot quiet point of a node without NM), the table configured and restored before the kernel
// (publishing every FB's input), then the server configured and the table bound to it.
fn (mut r Rig) reboot() {
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
	mounted := r.j.mount()
	if mounted {
		r.j.erase_pending()
	}
	r.ps = Params{}
	r.ps.p[steer] = Param{
		did:     0x0110
		id:      0x2001
		fp:      r.sch.steer_fp
		nfields: 1
	}
	r.ps.p[steer].fields[0] = Field{
		width: 2
		min:   0
		max:   r.sch.steer_max
		def:   r.sch.steer_def
	}
	r.ps.p[trailer] = Param{
		did:         0x0111
		id:          r.sch.trailer_id
		fp:          0x7272
		nfields:     1
		apply_reset: true
	}
	r.ps.p[trailer].fields[0] = Field{
		width: 1
		min:   0
		max:   1
		def:   0
	}
	r.ps.p[offset] = Param{
		did:     0x0112
		id:      0x2003
		fp:      0x0FF5
		nfields: 2
	}
	r.ps.p[offset].fields[0] = Field{
		width:  2
		signed: true
		min:    r.sch.offset_x_lo
		max:    100
		def:    0
	}
	r.ps.p[offset].fields[1] = Field{
		width:  1
		signed: true
		min:    -10
		max:    10
		def:    0
	}
	r.ps.n = 3
	r.ps.store = Store{
		ctx: r
		put: st_put
		get: st_get
	}
	r.ps.publish = st_publish
	r.ps.pub_ctx = r
	r.cell_a = [max_params]u32{}
	r.cell_b = [max_params]u32{}
	r.pubs = [max_params]int{}
	r.ps.restore(mounted)
	r.srv = uds.Server{}
	r.srv.init(64)
	r.srv.security = r.sa.ops(7)
	r.srv.security_levels = 0x01
	for k, id in [u16(0x0110), 0x0111, 0x0112] {
		r.srv.dids[k] = uds.Did{
			id:             id
			writable:       true
			write_sessions: uds.in_extended
			write_security: 1
		}
	}
	r.srv.dids[3] = uds.Did{
		id: status_did
	}
	r.srv.ndid = 4
	r.ps.bind(mut r.srv, status_did)
}

// req sends one physical request and returns the response.
fn (mut r Rig) req(b []u8) []u8 {
	mut out := [64]u8{}
	n := r.srv.handle(&b[0], b.len, &out[0])
	return out[..n].clone()
}

// unlock: the extended session and level 1, as a tester codes a vehicle.
fn (mut r Rig) unlock() {
	assert r.req([u8(0x10), 0x03])[0] == 0x50
	seed := r.req([u8(0x27), 0x01])
	assert seed[0] == 0x67
	mut k := [u8(0x27), 0x02]
	for b in seed[2..] {
		k << b ^ 0xFF
	}
	assert r.req(k) == [u8(0x67), 0x02]
}

fn (mut r Rig) write(did u16, data []u8) []u8 {
	mut b := [u8(0x2E), u8(did >> 8), u8(did)]
	b << data
	return r.req(b)
}

fn (mut r Rig) read(did u16) []u8 {
	resp := r.req([u8(0x22), u8(did >> 8), u8(did)])
	assert resp[0] == 0x62, 'read 0x${did.hex()}: ${resp}'
	return resp[3..]
}

fn (r &Rig) status(i int) u8 {
	return r.ps.p[i].status
}

fn test_an_uncoded_ecu_runs_its_defaults() {
	mut r := new_rig()
	assert r.cell_a[steer] == 360 // published before any FB runs
	assert r.pubs[steer] == 1 && r.pubs[trailer] == 1 && r.pubs[offset] == 1
	assert r.cell_a[trailer] == 0
	assert r.read(0x0110) == [u8(0x01), 0x68]
	assert r.read(0x0112) == [u8(0), 0, 0]
	assert r.read(status_did) == [u8(status_default), status_default, status_default]
	assert r.puts == 0
}

fn test_a_coded_value_is_gated_durable_and_applied_at_the_next_dispatch() {
	mut r := new_rig()
	// the DID's own gates first: default session, then no unlock
	assert r.write(0x0110, [u8(0x00), 0xC8]) == [u8(0x7F), 0x2E, 0x31]
	assert r.req([u8(0x10), 0x03])[0] == 0x50
	assert r.write(0x0110, [u8(0x00), 0xC8]) == [u8(0x7F), 0x2E, 0x33]
	assert r.puts == 0
	r.unlock()
	assert r.write(0x0110, [u8(0x00), 0xC8]) == [u8(0x6E), 0x01, 0x10] // 200
	assert r.puts == 1
	assert r.cell_a[steer] == 200 // the FB's next dispatch reads it
	assert r.read(0x0110) == [u8(0x00), 0xC8]
	assert r.read(status_did)[steer] == status_coded
	r.reboot()
	assert r.cell_a[steer] == 200
	assert r.read(0x0110) == [u8(0x00), 0xC8]
	assert r.status(steer) == status_coded
}

fn test_reset_applied_coding_waits_for_the_next_start() {
	mut r := new_rig()
	r.unlock()
	assert r.write(0x0111, [u8(0x01)]) == [u8(0x6E), 0x01, 0x11]
	assert r.cell_a[trailer] == 0 // the FB keeps the value it started with
	assert r.pubs[trailer] == 1
	assert r.read(0x0111) == [u8(0x01)] // 0x22 reads what the next start applies
	r.reboot()
	assert r.cell_a[trailer] == 1
	assert r.read(0x0111) == [u8(0x01)]
}

fn test_a_write_is_validated_before_anything_is_stored() {
	mut r := new_rig()
	r.unlock()
	assert r.write(0x0110, [u8(0x01), 0x69]) == [u8(0x7F), 0x2E, 0x31] // 361 > 360
	assert r.write(0x0110, [u8(0xC8)]) == [u8(0x7F), 0x2E, 0x13] // one byte of two
	assert r.write(0x0110, [u8(0x00), 0xC8, 0x00]) == [u8(0x7F), 0x2E, 0x13]
	assert r.write(0x0111, [u8(0x02)]) == [u8(0x7F), 0x2E, 0x31] // a bool is 0 or 1
	assert r.write(0x0112, [u8(0xFF), 0x9B, 0xF6]) == [u8(0x7F), 0x2E, 0x31] // x = -101 < -100
	assert r.write(0x0112, [u8(0x00), 0x00, 0x0B]) == [u8(0x7F), 0x2E, 0x31] // y = 11 > 10
	assert r.puts == 0
	assert r.cell_a[steer] == 360 && r.read(status_did) == [u8(0), 0, 0]
	// signed fields at their bounds: two's complement in the cell, big-endian on the wire
	assert r.write(0x0112, [u8(0xFF), 0x9C, 0xF6]) == [u8(0x6E), 0x01, 0x12] // (-100, -10)
	assert i16(r.cell_a[offset]) == -100 && i8(r.cell_b[offset]) == -10
	r.reboot()
	assert i16(r.cell_a[offset]) == -100 && i8(r.cell_b[offset]) == -10
	assert r.read(0x0112) == [u8(0xFF), 0x9C, 0xF6]
}

fn test_an_unchanged_value_writes_nothing() {
	mut r := new_rig()
	r.unlock()
	// the default written explicitly is coded once (an update that changes the default must not
	// move a vehicle coded to the old one) ...
	assert r.write(0x0110, [u8(0x01), 0x68])[0] == 0x6E
	assert r.puts == 1
	assert r.status(steer) == status_coded
	// ... and a tester polling the same value writes nothing more, across a restart too
	for _ in 0 .. 50 {
		assert r.write(0x0110, [u8(0x01), 0x68])[0] == 0x6E
	}
	assert r.puts == 1
	r.reboot()
	r.unlock()
	assert r.write(0x0110, [u8(0x01), 0x68])[0] == 0x6E
	assert r.puts == 1
	assert r.write(0x0110, [u8(0x00), 0x10])[0] == 0x6E
	assert r.puts == 2
	assert r.pubs[steer] == 2 // the restore's publish, then the one change
}

fn test_a_refused_write_answers_0x72_and_changes_nothing() {
	mut r := new_rig()
	r.unlock()
	assert r.write(0x0110, [u8(0x00), 0x64])[0] == 0x6E // 100
	r.f.refuse = true
	assert r.write(0x0110, [u8(0x00), 0xC8]) == [u8(0x7F), 0x2E, 0x72]
	assert r.cell_a[steer] == 100 // live unchanged
	assert r.read(0x0110) == [u8(0x00), 0x64] // the record unchanged
	assert r.pubs[steer] == 2
	assert r.write(0x0111, [u8(0x01)]) == [u8(0x7F), 0x2E, 0x72]
	assert r.read(status_did) == [u8(status_coded), status_default, status_default]
	r.f.refuse = false
	r.reboot()
	assert r.cell_a[steer] == 100 && r.cell_a[trailer] == 0 // durable unchanged
}

fn test_another_layout_is_never_applied() {
	mut r := new_rig()
	r.unlock()
	assert r.write(0x0110, [u8(0x00), 0x64])[0] == 0x6E
	assert r.write(0x0111, [u8(0x01)])[0] == 0x6E
	// an update changes SteerLimit's layout under its pinned id: the fingerprint refuses the old
	// bytes — the default, and the status says the coding was dropped
	r.sch.steer_fp = 0x5152
	// and moves TrailerFitted's block (a layout change unpinned: a new hash): nothing found
	r.sch.trailer_id = 0x2F02
	r.reboot()
	assert r.cell_a[steer] == 360
	assert r.read(0x0110) == [u8(0x01), 0x68]
	assert r.status(steer) == status_reverted
	assert r.cell_a[trailer] == 0
	assert r.status(trailer) == status_default
	// a write under the new layout is stored even when it equals the default (nothing of this
	// schema is durable), and from then on is the coding
	r.unlock()
	puts := r.puts
	assert r.write(0x0110, [u8(0x01), 0x68])[0] == 0x6E
	assert r.puts == puts + 1
	assert r.status(steer) == status_coded
}

fn test_a_restored_value_is_revalidated_against_this_firmwares_range() {
	mut r := new_rig()
	r.unlock()
	assert r.write(0x0110, [u8(0x01), 0x2C])[0] == 0x6E // 300
	assert r.write(0x0112, [u8(0xFF), 0xA6, 0x00])[0] == 0x6E // x = -90
	// an update narrows SteerLimit to 0..250 (default 250): the stored 300 is not applied
	r.sch.steer_max = 250
	r.sch.steer_def = 250
	r.sch.offset_x_lo = -50 // and Offset.x to -50..100: (-90, 0) is refused whole
	r.reboot()
	assert r.cell_a[steer] == 250
	assert r.read(0x0110) == [u8(0x00), 0xFA]
	assert r.cell_a[offset] == 0 && r.cell_b[offset] == 0
	assert r.read(status_did) == [u8(status_reverted), status_default, status_reverted]
	// a write of what the narrowed range allows is stored, though it equals the default
	r.unlock()
	puts := r.puts
	assert r.write(0x0110, [u8(0x00), 0xFA])[0] == 0x6E
	assert r.puts == puts + 1
	// widening the range keeps a coding: the bytes still mean what they meant
	r.sch.steer_max = 360
	r.sch.steer_def = 360
	r.reboot()
	assert r.cell_a[steer] == 250 && r.status(steer) == status_coded
}

fn test_an_unreadable_journal_runs_the_defaults_and_says_so() {
	mut r := new_rig()
	r.ps.restore(false)
	assert r.cell_a[steer] == 360
	for i in 0 .. 3 {
		assert r.status(i) == status_reverted
	}
}

fn test_a_bound_did_without_the_seam_refuses() {
	mut s := uds.Server{}
	s.init(64)
	s.dids[0] = uds.Did{
		id:       0x0110
		writable: true
		bound:    true
	}
	s.ndid = 1
	mut out := [8]u8{}
	req := [u8(0x2E), 0x01, 0x10, 0x00, 0x01]
	n := s.handle(&req[0], req.len, &out[0])
	assert out[..n] == [u8(0x7F), 0x2E, 0x22]
	assert s.dids[0].len == 0
}

// rng: a deterministic xorshift for the fuzz
struct Rng {
mut:
	s u32
}

fn (mut g Rng) next(n u32) u32 {
	g.s ^= g.s << 13
	g.s ^= g.s >> 17
	g.s ^= g.s << 5
	return g.s % n
}

// Power cut anywhere: a reference model holds, per parameter, the value last ACKNOWLEDGED (the
// tester got 0x6E) and the one in flight. A random sequence of writes — in range, out of range,
// repeats — runs with the power cut at a random flash program inside a write (inline compactions
// included), or the store refusing. After every boot each parameter restores exactly its
// acknowledged value, or the one whose write the cut interrupted — never another parameter's bytes,
// never an out-of-range value, never a refused one; and what the FBs read is what 0x22 reads.
fn test_power_cuts_anywhere_leave_an_acknowledged_coding() {
	mut r := new_rig()
	mut g := Rng{
		s: 0x1234567
	}
	mut ack := [[i64(360)], [i64(0)], [i64(0), 0]]
	widths := [[2], [1], [2, 1]]
	lo := [[i64(0)], [i64(0)], [i64(-100), -10]]
	hi := [[i64(360)], [i64(1)], [i64(100), 10]]
	mut cuts := 0
	mut wrote := 0
	r.unlock()
	for step in 0 .. 4000 {
		i := int(g.next(3))
		mut v := []i64{}
		for f in 0 .. widths[i].len {
			span := hi[i][f] - lo[i][f] + 1
			x := match g.next(4) {
				0 { ack[i][f] } // a repeat
				1 { hi[i][f] + 1 + i64(g.next(3)) } // out of range
				else { lo[i][f] + i64(g.next(u32(span))) }
			}
			v << x
		}
		mut data := []u8{}
		for f, x in v {
			for k := widths[i][f] - 1; k >= 0; k-- {
				data << u8(u64(x) >> (8 * k))
			}
		}
		cut := g.next(5) == 0
		if cut {
			r.f.cut_at = r.f.calls + 1 + g.next(3)
			r.f.cut_part = g.next(40)
		}
		r.f.refuse = !cut && g.next(20) == 0
		resp := r.write(u16(0x0110 + i), data)
		r.f.refuse = false
		mut in_range := true
		for f, x in v {
			if x < lo[i][f] || x > hi[i][f] {
				in_range = false
			}
		}
		if resp[0] == 0x6E {
			assert in_range, 'step ${step}: an out-of-range value was accepted'
			ack[i] = v.clone()
			wrote++
		} else if !r.f.dead {
			assert !in_range || resp[2] == 0x72, 'step ${step}: ${resp}'
		}
		if r.f.dead || g.next(50) == 0 {
			inflight := if r.f.dead { v.clone() } else { []i64{} }
			if r.f.dead {
				cuts++
			}
			r.reboot()
			for k in 0 .. 3 {
				mut got := []i64{}
				for f in 0 .. widths[k].len {
					got << r.ps.p[k].stored[f]
					assert r.ps.p[k].live[f] == r.ps.p[k].stored[f]
				}
				if k == i && inflight.len > 0 && got == inflight {
					ack[k] = got.clone() // the interrupted write had reached the journal whole
				}
				assert got == ack[k], 'step ${step}: param ${k} restored ${got}, acknowledged ${ack[k]}'
				mut want := []u8{}
				for f, x in got {
					for b := widths[k][f] - 1; b >= 0; b-- {
						want << u8(u64(x) >> (8 * b))
					}
				}
				assert r.read(u16(0x0110 + k)) == want // 0x22 reads what the FBs were given
				assert r.cell_a[k] == u32(u64(got[0])) // ... and so does their cell
			}
			r.unlock()
		}
	}
	assert cuts > 100 && wrote > 1000, 'the fuzz exercised too little: ${cuts} cuts, ${wrote} writes'
}
