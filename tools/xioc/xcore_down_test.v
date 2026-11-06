module main

// The owner -> satellite cross-core signals (boards/h755zi/xcore_owner.c, xcore_sat.c) on the
// host: the owner-written window is an ordinary array (testdata/xcore_gen.h overrides
// XCORE_OW_BASE), and both halves run against it. Covered: the gate on cold boot (garbage or
// zero), publish and read at 1, 2 and 16 lanes, an owner re-init resetting the reader to the
// default until the first new publish, a different build and a width mismatch reading as
// never-fresh, a new sequence seed per owner boot, and a retracted ack closing the gate.

#flag -I @VMODROOT/tools/xioc/testdata
#flag -I @VMODROOT/boards/h755zi
#flag -I @VMODROOT/boards/common
#include "xcore_gen.h"
#include "xcore_owner.c"
#include "xcore_sat.c"

fn C.xcore_owner_begin()
fn C.xcore_ow_init(off u32, words u32)
fn C.xcore_owner_commit()
fn C.xcore_opub_n(off u32, src &u32)
fn C.xcore_down_read(off u32, words u32, st &u32) int
fn C.xcore_test_sram() &u32
fn C.xcore_ow_ack(v u32) u32
fn C.xcore_busy_pub(core int, pm int)
fn C.xcore_busy_get(core int) int
fn C.xcore_test_busy_slots() &u32
fn C.xcore_busy_watch()

const layout_id = u32(0x1234ABCD)
const sram_words = 1024
// channel offsets from XCORE_OW_CH_ADDR: XIOC_N_BYTES(1) = 64, XIOC_N_BYTES(2) = 96
const off1 = u32(0)
const off2 = u32(64)
const off16 = u32(160)

fn sram_set(i int, v u32) {
	unsafe {
		mut p := C.xcore_test_sram()
		p[i] = v
	}
}

fn sram_get(i int) u32 {
	return unsafe { C.xcore_test_sram()[i] }
}

fn fill_sram(v u32) {
	for i in 0 .. sram_words {
		sram_set(i, v ^ (u32(i) * 2654435761))
	}
}

// the channel's writer-private publish counter: after init it is the boot's seed
fn chan_wseq(off u32) u32 {
	return sram_get(int((0x20 + off) / 4) + 1)
}

fn owner_boot() {
	C.xcore_owner_begin()
	C.xcore_ow_init(off1, 1)
	C.xcore_ow_init(off2, 2)
	C.xcore_ow_init(off16, 16)
	C.xcore_owner_commit()
}

fn lanes_zero(st [18]u32, words int) bool {
	for i in 0 .. words {
		if st[2 + i] != 0 {
			return false
		}
	}
	return true
}

fn test_cold_boot_gate_is_closed() {
	mut st := [18]u32{init: 0xDEADBEEF}
	fill_sram(0xA5A5A5A5)
	assert C.xcore_down_read(off16, 16, &st[0]) == 0
	assert st[0] == 0 && st[1] == 0 && lanes_zero(st, 16), 'a closed gate zeroes the reader state'
	fill_sram(0)
	for i in 0 .. 18 {
		st[i] = 0xDEADBEEF
	}
	assert C.xcore_down_read(off1, 1, &st[0]) == 0
	assert st[0] == 0 && st[1] == 0 && st[2] == 0
}

fn test_publish_and_read_at_each_width() {
	fill_sram(0x5A5A5A5A)
	owner_boot()
	nonce := sram_get(1)
	assert nonce & 1 == 1, 'the nonce is odd'
	assert sram_get(0) == C.xcore_ow_ack(nonce ^ layout_id)
	mut s1 := [18]u32{}
	mut s2 := [18]u32{}
	mut s16 := [18]u32{}
	// initialised, nothing published: the default
	assert C.xcore_down_read(off1, 1, &s1[0]) == 0
	assert s1[0] == nonce && s1[2] == 0
	mut src := [16]u32{}
	src[0] = 7
	C.xcore_opub_n(off1, &src[0])
	src[0] = 0xFFFFFFFF
	src[1] = 0x80000000
	C.xcore_opub_n(off2, &src[0])
	for i in 0 .. 16 {
		src[i] = 1000 + u32(i)
	}
	C.xcore_opub_n(off16, &src[0])
	assert C.xcore_down_read(off1, 1, &s1[0]) == 1
	assert s1[2] == 7
	assert C.xcore_down_read(off2, 2, &s2[0]) == 1
	assert s2[2] == 0xFFFFFFFF && s2[3] == 0x80000000
	assert C.xcore_down_read(off16, 16, &s16[0]) == 1
	for i in 0 .. 16 {
		assert s16[2 + i] == 1000 + u32(i)
	}
	// nothing new: the value published in this boot is still held
	assert C.xcore_down_read(off1, 1, &s1[0]) == 1
	assert s1[2] == 7
}

fn test_owner_reinit_resets_the_reader_to_default() {
	fill_sram(0)
	owner_boot()
	mut st := [18]u32{}
	mut src := [16]u32{}
	src[0] = 41
	C.xcore_opub_n(off1, &src[0])
	assert C.xcore_down_read(off1, 1, &st[0]) == 1
	assert st[2] == 41
	first := sram_get(1)
	// a new owner boot the reader does not see mid-way: the nonce moves, the reader resets
	owner_boot()
	assert sram_get(1) != first, 'the nonce changes per owner boot'
	assert C.xcore_down_read(off1, 1, &st[0]) == 0
	assert st[0] == sram_get(1) && st[1] == 0 && st[2] == 0
	src[0] = 42
	C.xcore_opub_n(off1, &src[0])
	assert C.xcore_down_read(off1, 1, &st[0]) == 1
	assert st[2] == 42
	// a re-init the reader polls through: closed between begin and commit, default after
	C.xcore_owner_begin()
	assert sram_get(0) == 0, 'begin retracts the ack first'
	assert C.xcore_down_read(off1, 1, &st[0]) == 0
	assert st[0] == 0 && st[2] == 0
	C.xcore_ow_init(off1, 1)
	C.xcore_owner_commit()
	assert C.xcore_down_read(off1, 1, &st[0]) == 0
	assert st[2] == 0
	src[0] = 43
	C.xcore_opub_n(off1, &src[0])
	assert C.xcore_down_read(off1, 1, &st[0]) == 1
	assert st[2] == 43
}

fn test_a_different_build_is_never_fresh() {
	fill_sram(0)
	owner_boot()
	nonce := sram_get(1)
	// the ack an owner built with another layout id writes
	sram_set(0, C.xcore_ow_ack(nonce ^ 0x0BADC0DE))
	mut src := [16]u32{}
	mut st := [18]u32{}
	for n in 1 .. 4 {
		src[0] = u32(n)
		C.xcore_opub_n(off1, &src[0])
		assert C.xcore_down_read(off1, 1, &st[0]) == 0
		assert st[0] == 0 && st[1] == 0 && st[2] == 0
	}
}

fn test_a_width_mismatch_is_never_fresh() {
	fill_sram(0)
	owner_boot()
	mut src := [16]u32{init: 9}
	C.xcore_opub_n(off1, &src[0])
	C.xcore_opub_n(off2, &src[0])
	mut st := [18]u32{}
	assert C.xcore_down_read(off1, 2, &st[0]) == 0
	assert st[1] == 0 && lanes_zero(st, 2)
	assert C.xcore_down_read(off2, 1, &st[0]) == 0
	assert st[1] == 0 && st[2] == 0
	assert C.xcore_down_read(off16, 15, &st[0]) == 0
	assert st[1] == 0 && lanes_zero(st, 15)
}

fn test_the_seed_differs_between_boots() {
	fill_sram(0)
	owner_boot()
	a := chan_wseq(off1)
	owner_boot()
	b := chan_wseq(off1)
	owner_boot()
	c := chan_wseq(off1)
	assert a != b && b != c && a != c
	assert a & 1 == 1 && b & 1 == 1
	assert chan_wseq(off2) == c && chan_wseq(off16) == c, 'one seed per owner boot'
}

fn test_retract_closes_the_gate() {
	fill_sram(0)
	owner_boot()
	mut src := [16]u32{}
	src[0] = 5
	C.xcore_opub_n(off1, &src[0])
	mut st := [18]u32{}
	assert C.xcore_down_read(off1, 1, &st[0]) == 1
	// what boot_park_satellite does
	sram_set(0, 0)
	assert C.xcore_down_read(off1, 1, &st[0]) == 0
	assert st[0] == 0 && st[1] == 0 && st[2] == 0
	src[0] = 6
	C.xcore_opub_n(off1, &src[0])
	assert C.xcore_down_read(off1, 1, &st[0]) == 0
}

// the busy slots (each satellite's total load for the owner's ps): an owner boot clears what a
// previous boot left, and a core counts as reporting only while it published since the last load
// window, so one that never reports or stops reads as not measured, never as idle or as its last
// value
fn test_busy_slots_read_as_not_measured_unless_a_satellite_keeps_reporting() {
	unsafe {
		mut b := C.xcore_test_busy_slots()
		for c in 0 .. 8 {
			b[c] = u32(123) | (u32(7) << 16) // retained from a previous boot
		}
	}
	C.xcore_owner_begin()
	C.xcore_busy_watch()
	for c in 0 .. 8 {
		assert C.xcore_busy_get(c) == -1, 'core ${c} before any report'
	}
	C.xcore_busy_pub(1, 185)
	assert C.xcore_busy_get(1) == -1, 'not reporting until a window has seen it publish'
	C.xcore_busy_watch()
	assert C.xcore_busy_get(1) == 185
	assert C.xcore_busy_get(2) == -1, 'one core reporting sets its own slot only'
	C.xcore_busy_watch() // a window with no publish: the core stopped
	assert C.xcore_busy_get(1) == -1, 'a core that stopped publishing keeps no stale value'
	C.xcore_busy_pub(1, 190)
	C.xcore_busy_watch()
	assert C.xcore_busy_get(1) == 190, 'reporting again'
	C.xcore_busy_pub(1, -1) // an image without the hooks
	C.xcore_busy_watch()
	assert C.xcore_busy_get(1) == -1
	C.xcore_busy_pub(8, 500) // no such slot: nothing written
	C.xcore_busy_watch()
	assert C.xcore_busy_get(8) == -1 && C.xcore_busy_get(-1) == -1
}
