module app

// The load FBs on the CM4 (nodes/domain/ecu.toml, "Load FBs"), as load_main.v's on the CM7.

import ports

// LCG steps per dispatch: about 77 us on the CM4 at 200 MHz, with its ART cache on
const sat_load_burn = 2000

pub struct SatLoadA {
pub mut:
	ticks u32
	acc   u32 = 1
}

pub fn (mut fb SatLoadA) on_10ms(inp ports.SatLoadAIn, mut out ports.SatLoadAOut) {
	fb.ticks++
	fb.acc = load_step(fb.acc, sat_load_burn)
	v := load_hop(inp.main_ld_j.v)
	out.sat_ld_a.v = v
	out.sat_ld_a.seq = fb.ticks
	out.sat_ld_a.chk = load_chk(v, fb.ticks)
}

pub struct SatLoadB {
pub mut:
	ticks u32
	acc   u32 = 2
}

pub fn (mut fb SatLoadB) on_10ms(inp ports.SatLoadBIn, mut out ports.SatLoadBOut) {
	fb.ticks++
	fb.acc = load_step(fb.acc, sat_load_burn)
	v := load_hop(inp.sat_ld_a.v)
	out.sat_ld_b.v = v
	out.sat_ld_b.seq = fb.ticks
	out.sat_ld_b.chk = load_chk(v, fb.ticks)
}

pub struct SatLoadC {
pub mut:
	ticks u32
	acc   u32 = 3
}

pub fn (mut fb SatLoadC) on_10ms(inp ports.SatLoadCIn, mut out ports.SatLoadCOut) {
	fb.ticks++
	fb.acc = load_step(fb.acc, sat_load_burn)
	v := load_hop(inp.sat_ld_b.v)
	out.sat_ld_c.v = v
	out.sat_ld_c.seq = fb.ticks
	out.sat_ld_c.chk = load_chk(v, fb.ticks)
}

pub struct SatLoadD {
pub mut:
	ticks u32
	acc   u32 = 4
}

pub fn (mut fb SatLoadD) on_10ms(inp ports.SatLoadDIn, mut out ports.SatLoadDOut) {
	fb.ticks++
	fb.acc = load_step(fb.acc, sat_load_burn)
	v := load_hop(inp.sat_ld_c.v)
	out.sat_ld_d.v = v
	out.sat_ld_d.seq = fb.ticks
	out.sat_ld_d.chk = load_chk(v, fb.ticks)
}

pub struct SatLoadE {
pub mut:
	ticks u32
	acc   u32 = 5
}

pub fn (mut fb SatLoadE) on_10ms(inp ports.SatLoadEIn, mut out ports.SatLoadEOut) {
	fb.ticks++
	fb.acc = load_step(fb.acc, sat_load_burn)
	v := load_hop(inp.sat_ld_d.v)
	out.sat_ld_e.v = v
	out.sat_ld_e.seq = fb.ticks
	out.sat_ld_e.chk = load_chk(v, fb.ticks)
}

pub struct SatLoadF {
pub mut:
	ticks u32
	acc   u32 = 6
}

pub fn (mut fb SatLoadF) on_10ms(inp ports.SatLoadFIn, mut out ports.SatLoadFOut) {
	fb.ticks++
	fb.acc = load_step(fb.acc, sat_load_burn)
	// the CM7's MainLdO and this core's SatLdE carry the same hop count: the chain goes on only
	// while both paths agree, so a break in either shows on LoadOutC and LoadOutD
	v := if inp.main_ld_o.v == inp.sat_ld_e.v { load_hop(inp.sat_ld_e.v) } else { u32(0xFFFF_FFFF) }
	out.sat_ld_f.v = v
	out.sat_ld_f.seq = fb.ticks
	out.sat_ld_f.chk = load_chk(v, fb.ticks)
}

pub struct SatLoadG {
pub mut:
	ticks u32
	acc   u32 = 7
}

pub fn (mut fb SatLoadG) on_10ms(inp ports.SatLoadGIn, mut out ports.SatLoadGOut) {
	fb.ticks++
	fb.acc = load_step(fb.acc, sat_load_burn)
	v := load_hop(inp.sat_ld_f.v)
	out.sat_ld_g.v = v
	out.sat_ld_g.seq = fb.ticks
	out.sat_ld_g.chk = load_chk(v, fb.ticks)
}

pub struct SatLoadH {
pub mut:
	ticks u32
	acc   u32 = 8
}

pub fn (mut fb SatLoadH) on_10ms(inp ports.SatLoadHIn, mut out ports.SatLoadHOut) {
	fb.ticks++
	fb.acc = load_step(fb.acc, sat_load_burn)
	v := load_hop(inp.sat_ld_g.v)
	out.sat_ld_h.v = v
	out.sat_ld_h.seq = fb.ticks
	out.sat_ld_h.chk = load_chk(v, fb.ticks)
}

pub struct SatLoadI {
pub mut:
	ticks u32
	acc   u32 = 9
}

pub fn (mut fb SatLoadI) on_10ms(inp ports.SatLoadIIn, mut out ports.SatLoadIOut) {
	fb.ticks++
	fb.acc = load_step(fb.acc, sat_load_burn)
	v := load_hop(inp.sat_ld_h.v)
	out.sat_ld_i.v = v
	out.sat_ld_i.seq = fb.ticks
	out.sat_ld_i.chk = load_chk(v, fb.ticks)
}

pub struct SatLoadJ {
pub mut:
	ticks u32
	acc   u32 = 10
}

pub fn (mut fb SatLoadJ) on_10ms(inp ports.SatLoadJIn, mut out ports.SatLoadJOut) {
	fb.ticks++
	fb.acc = load_step(fb.acc, sat_load_burn)
	v := load_hop(inp.sat_ld_i.v)
	out.sat_ld_j.v = v
	out.sat_ld_j.seq = fb.ticks
	out.sat_ld_j.chk = load_chk(v, fb.ticks)
}
