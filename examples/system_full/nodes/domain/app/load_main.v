module app

// The load FBs on the CM7 (nodes/domain/ecu.toml, "Load FBs"): a 10 ms handler each, burning
// a bounded LCG window and passing a hop count on. The point is the load and the signals
// flowing, not what they compute.

import ports

// LCG steps per dispatch: about 13 us on the CM7 at 400 MHz
const main_load_burn = 2000

// load_step: one dispatch's burn, kept in the FB's state so it is never dead code
fn load_step(acc u32, n int) u32 {
	mut a := acc
	for _ in 0 .. n {
		a = a * 1664525 + 1013904223
	}
	return a
}

// load_hop: the chain's next hop count, a mismatch marker (0xFFFFFFFF) passed on as it is, so a
// check that failed upstream reaches the bus as the marker and never as an ordinary count
fn load_hop(v u32) u32 {
	return if v == 0xFFFF_FFFF { v } else { v + 1 }
}

// load_chk: the check lane a load signal carries beside its value and sequence
fn load_chk(v u32, seq u32) u32 {
	return v ^ seq ^ 0x5A5A_5A5A
}

// load_seen: a load signal read from the other core, 0xFFFFFFFF when its lanes do not
// belong together (0 before its first publish, the port default)
fn load_seen(v u32, seq u32, chk u32) u32 {
	return if seq != 0 && chk != load_chk(v, seq) { u32(0xFFFF_FFFF) } else { v }
}

pub struct MainLoadA {
pub mut:
	ticks u32
	acc   u32 = 1
}

pub fn (mut fb MainLoadA) on_10ms(inp ports.MainLoadAIn, mut out ports.MainLoadAOut) {
	fb.ticks++
	fb.acc = load_step(fb.acc, main_load_burn)
	v := load_hop(inp.host_led_level.permille)
	out.main_ld_a.v = v
	out.main_ld_a.seq = fb.ticks
	out.main_ld_a.chk = load_chk(v, fb.ticks)
}

pub struct MainLoadB {
pub mut:
	ticks u32
	acc   u32 = 2
}

pub fn (mut fb MainLoadB) on_10ms(inp ports.MainLoadBIn, mut out ports.MainLoadBOut) {
	fb.ticks++
	fb.acc = load_step(fb.acc, main_load_burn)
	v := load_hop(inp.main_ld_a.v)
	out.main_ld_b.v = v
	out.main_ld_b.seq = fb.ticks
	out.main_ld_b.chk = load_chk(v, fb.ticks)
}

pub struct MainLoadC {
pub mut:
	ticks u32
	acc   u32 = 3
}

pub fn (mut fb MainLoadC) on_10ms(inp ports.MainLoadCIn, mut out ports.MainLoadCOut) {
	fb.ticks++
	fb.acc = load_step(fb.acc, main_load_burn)
	v := load_hop(inp.main_ld_b.v)
	out.main_ld_c.v = v
	out.main_ld_c.seq = fb.ticks
	out.main_ld_c.chk = load_chk(v, fb.ticks)
}

pub struct MainLoadD {
pub mut:
	ticks u32
	acc   u32 = 4
}

pub fn (mut fb MainLoadD) on_10ms(inp ports.MainLoadDIn, mut out ports.MainLoadDOut) {
	fb.ticks++
	fb.acc = load_step(fb.acc, main_load_burn)
	v := load_hop(inp.main_ld_c.v)
	out.main_ld_d.v = v
	out.main_ld_d.seq = fb.ticks
	out.main_ld_d.chk = load_chk(v, fb.ticks)
}

pub struct MainLoadE {
pub mut:
	ticks u32
	acc   u32 = 5
}

pub fn (mut fb MainLoadE) on_10ms(inp ports.MainLoadEIn, mut out ports.MainLoadEOut) {
	fb.ticks++
	fb.acc = load_step(fb.acc, main_load_burn)
	v := load_hop(inp.main_ld_d.v)
	out.main_ld_e.v = v
	out.main_ld_e.seq = fb.ticks
	out.main_ld_e.chk = load_chk(v, fb.ticks)
	out.load_out_a.v = load_seen(inp.sat_ld_c.v, inp.sat_ld_c.seq, inp.sat_ld_c.chk) // what came up from the CM4
}

pub struct MainLoadF {
pub mut:
	ticks u32
	acc   u32 = 6
}

pub fn (mut fb MainLoadF) on_10ms(inp ports.MainLoadFIn, mut out ports.MainLoadFOut) {
	fb.ticks++
	fb.acc = load_step(fb.acc, main_load_burn)
	v := load_hop(inp.main_ld_e.v)
	out.main_ld_f.v = v
	out.main_ld_f.seq = fb.ticks
	out.main_ld_f.chk = load_chk(v, fb.ticks)
}

pub struct MainLoadG {
pub mut:
	ticks u32
	acc   u32 = 7
}

pub fn (mut fb MainLoadG) on_10ms(inp ports.MainLoadGIn, mut out ports.MainLoadGOut) {
	fb.ticks++
	fb.acc = load_step(fb.acc, main_load_burn)
	v := load_hop(inp.main_ld_f.v)
	out.main_ld_g.v = v
	out.main_ld_g.seq = fb.ticks
	out.main_ld_g.chk = load_chk(v, fb.ticks)
}

pub struct MainLoadH {
pub mut:
	ticks u32
	acc   u32 = 8
}

pub fn (mut fb MainLoadH) on_10ms(inp ports.MainLoadHIn, mut out ports.MainLoadHOut) {
	fb.ticks++
	fb.acc = load_step(fb.acc, main_load_burn)
	v := load_hop(inp.main_ld_g.v)
	out.main_ld_h.v = v
	out.main_ld_h.seq = fb.ticks
	out.main_ld_h.chk = load_chk(v, fb.ticks)
}

pub struct MainLoadI {
pub mut:
	ticks u32
	acc   u32 = 9
}

pub fn (mut fb MainLoadI) on_10ms(inp ports.MainLoadIIn, mut out ports.MainLoadIOut) {
	fb.ticks++
	fb.acc = load_step(fb.acc, main_load_burn)
	v := load_hop(inp.main_ld_h.v)
	out.main_ld_i.v = v
	out.main_ld_i.seq = fb.ticks
	out.main_ld_i.chk = load_chk(v, fb.ticks)
}

pub struct MainLoadJ {
pub mut:
	ticks u32
	acc   u32 = 10
}

pub fn (mut fb MainLoadJ) on_10ms(inp ports.MainLoadJIn, mut out ports.MainLoadJOut) {
	fb.ticks++
	fb.acc = load_step(fb.acc, main_load_burn)
	v := load_hop(inp.main_ld_i.v)
	out.main_ld_j.v = v
	out.main_ld_j.seq = fb.ticks
	out.main_ld_j.chk = load_chk(v, fb.ticks)
	out.load_out_b.v = v
}

pub struct MainLoadK {
pub mut:
	ticks u32
	acc   u32 = 11
}

pub fn (mut fb MainLoadK) on_10ms(inp ports.MainLoadKIn, mut out ports.MainLoadKOut) {
	fb.ticks++
	fb.acc = load_step(fb.acc, main_load_burn)
	v := load_hop(inp.main_ld_j.v)
	out.main_ld_k.v = v
	out.main_ld_k.seq = fb.ticks
	out.main_ld_k.chk = load_chk(v, fb.ticks)
}

pub struct MainLoadL {
pub mut:
	ticks u32
	acc   u32 = 12
}

pub fn (mut fb MainLoadL) on_10ms(inp ports.MainLoadLIn, mut out ports.MainLoadLOut) {
	fb.ticks++
	fb.acc = load_step(fb.acc, main_load_burn)
	v := load_hop(inp.main_ld_k.v)
	out.main_ld_l.v = v
	out.main_ld_l.seq = fb.ticks
	out.main_ld_l.chk = load_chk(v, fb.ticks)
	out.load_out_c.v = load_seen(inp.sat_ld_g.v, inp.sat_ld_g.seq, inp.sat_ld_g.chk) // what came up from the CM4
}

pub struct MainLoadM {
pub mut:
	ticks u32
	acc   u32 = 13
}

pub fn (mut fb MainLoadM) on_10ms(inp ports.MainLoadMIn, mut out ports.MainLoadMOut) {
	fb.ticks++
	fb.acc = load_step(fb.acc, main_load_burn)
	v := load_hop(inp.main_ld_l.v)
	out.main_ld_m.v = v
	out.main_ld_m.seq = fb.ticks
	out.main_ld_m.chk = load_chk(v, fb.ticks)
}

pub struct MainLoadN {
pub mut:
	ticks u32
	acc   u32 = 14
}

pub fn (mut fb MainLoadN) on_10ms(inp ports.MainLoadNIn, mut out ports.MainLoadNOut) {
	fb.ticks++
	fb.acc = load_step(fb.acc, main_load_burn)
	v := load_hop(inp.main_ld_m.v)
	out.main_ld_n.v = v
	out.main_ld_n.seq = fb.ticks
	out.main_ld_n.chk = load_chk(v, fb.ticks)
}

pub struct MainLoadO {
pub mut:
	ticks u32
	acc   u32 = 15
}

pub fn (mut fb MainLoadO) on_10ms(inp ports.MainLoadOIn, mut out ports.MainLoadOOut) {
	fb.ticks++
	fb.acc = load_step(fb.acc, main_load_burn)
	v := load_hop(inp.main_ld_n.v)
	out.main_ld_o.v = v
	out.main_ld_o.seq = fb.ticks
	out.main_ld_o.chk = load_chk(v, fb.ticks)
}

pub struct MainLoadP {
pub mut:
	ticks u32
	acc   u32 = 16
}

pub fn (mut fb MainLoadP) on_10ms(inp ports.MainLoadPIn, mut out ports.MainLoadPOut) {
	fb.ticks++
	fb.acc = load_step(fb.acc, main_load_burn)
	v := load_hop(inp.main_ld_o.v)
	out.main_ld_p.v = v
	out.main_ld_p.seq = fb.ticks
	out.main_ld_p.chk = load_chk(v, fb.ticks)
}

pub struct MainLoadQ {
pub mut:
	ticks u32
	acc   u32 = 17
}

pub fn (mut fb MainLoadQ) on_10ms(inp ports.MainLoadQIn, mut out ports.MainLoadQOut) {
	fb.ticks++
	fb.acc = load_step(fb.acc, main_load_burn)
	v := load_hop(inp.main_ld_p.v)
	out.main_ld_q.v = v
	out.main_ld_q.seq = fb.ticks
	out.main_ld_q.chk = load_chk(v, fb.ticks)
}

pub struct MainLoadR {
pub mut:
	ticks u32
	acc   u32 = 18
}

pub fn (mut fb MainLoadR) on_10ms(inp ports.MainLoadRIn, mut out ports.MainLoadROut) {
	fb.ticks++
	fb.acc = load_step(fb.acc, main_load_burn)
	v := load_hop(inp.main_ld_q.v)
	out.main_ld_r.v = v
	out.main_ld_r.seq = fb.ticks
	out.main_ld_r.chk = load_chk(v, fb.ticks)
	out.load_out_d.v = load_seen(inp.sat_ld_j.v, inp.sat_ld_j.seq, inp.sat_ld_j.chk) // what came up from the CM4
}

pub struct MainLoadS {
pub mut:
	ticks u32
	acc   u32 = 19
}

pub fn (mut fb MainLoadS) on_10ms(inp ports.MainLoadSIn, mut out ports.MainLoadSOut) {
	fb.ticks++
	fb.acc = load_step(fb.acc, main_load_burn)
	v := load_hop(inp.main_ld_r.v)
	out.main_ld_s.v = v
	out.main_ld_s.seq = fb.ticks
	out.main_ld_s.chk = load_chk(v, fb.ticks)
}

pub struct MainLoadT {
pub mut:
	ticks u32
	acc   u32 = 20
}

pub fn (mut fb MainLoadT) on_10ms(inp ports.MainLoadTIn, mut out ports.MainLoadTOut) {
	fb.ticks++
	fb.acc = load_step(fb.acc, main_load_burn)
	v := load_hop(inp.main_ld_s.v)
	out.main_ld_t.v = v
	out.main_ld_t.seq = fb.ticks
	out.main_ld_t.chk = load_chk(v, fb.ticks)
	out.load_out_e.v = v
}
