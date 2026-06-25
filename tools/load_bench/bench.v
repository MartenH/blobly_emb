// load_bench — a system-scale CPU-load test. Models a 4-core ECU where 8 CAN
// buses hang off core0, every core runs 50 Function Blocks, and each FB reads 10
// signals and writes 10 (a mix of CAN-bridged signals via core0 and cross-core
// internal ones) every 10 ms. Runs a few seconds and reports the CPU load on each
// core.
//
// Real AMP: one process per core (fork + pin), sharing only the mmap'd IOC region
// — the same substrate as ioc_bench_mp and the ThreadX-AMP port. Each core measures
// its own CPU time (CLOCK_PROCESS_CPUTIME_ID) vs wall time = its load.
//
//   v -gc none run tools/load_bench/bench.v
module main

import osal

#include <time.h>

const cores = 4
const buses_on_core0 = 8
const sigs_per_bus = 8 // signals decoded (rx) and encoded (tx) per bus per cycle
const fbs_per_core = 50
const reads_per_fb = 10
const writes_per_fb = 10
const cycle_us = u64(10_000) // 10 ms task cycle
const run_s = u64(3)
const nch = 8 // triple-buffer IOC channels (the wait-free default)

// A small signal record (value + a few fields), like a real signal payload.
struct Sig {
mut:
	seq u32
	v0  u32
	v1  u32
	v2  u32
}

struct C.timespec {
	tv_sec  i64
	tv_nsec i64
}

fn C.clock_gettime(int, &C.timespec) int

// cpu_ns returns this process's consumed CPU time (not wall) in nanoseconds.
fn cpu_ns() u64 {
	ts := C.timespec{}
	C.clock_gettime(2, &ts) // 2 = CLOCK_PROCESS_CPUTIME_ID
	return u64(ts.tv_sec) * 1_000_000_000 + u64(ts.tv_nsec)
}

fn scratch() &u64 {
	return unsafe { &u64(osal.shared_scratch()) }
}

// decode16 / encode16: representative DBC-style bit work over a frame payload —
// the same per-bit loop the generated codec uses.
fn decode16(frame &u8, bit int) u32 {
	mut raw := u32(0)
	for i in 0 .. 16 {
		g := bit + i
		b := unsafe { (frame[g / 8] >> u32(g % 8)) & 1 }
		raw |= u32(b) << u32(i)
	}
	return raw
}

fn encode16(mut frame [64]u8, bit int, val u32) {
	for i in 0 .. 16 {
		g := bit + i
		bitv := u8((val >> u32(i)) & 1)
		mask := u8(1) << u32(g % 8)
		frame[g / 8] = (frame[g / 8] & ~mask) | (bitv << u32(g % 8))
	}
}

// bridge_work: one CAN bus serviced on core0 — decode sigs_per_bus signals from an
// rx frame and publish them, then acquire sigs_per_bus and encode a tx frame.
fn bridge_work(bus int) {
	mut rx := [64]u8{}
	for i in 0 .. 64 {
		rx[i] = u8(bus * 7 + i)
	}
	for s in 0 .. sigs_per_bus {
		v := decode16(&rx[0], (s * 16) % 48)
		mut sig := Sig{
			v0: v
			v1: v + 1
		}
		osal.ioc_publish(bus % 2, &sig, u8(sizeof(sig))) // core0's channels
	}
	mut tx := [64]u8{}
	for s in 0 .. sigs_per_bus {
		mut sig := Sig{}
		osal.ioc_acquire(2 + (bus + s) % 6, &sig, u8(sizeof(sig))) // other cores' (CAN tx)
		encode16(mut tx, (s * 16) % 48, sig.v0)
	}
}

// fb_work: one FB cycle — read 10 signals (cross-core, incl. CAN-bridged), compute,
// write 10 signals to this core's channels (single-writer per core).
fn fb_work(core int, fb int) {
	mut acc := u32(core * 1000 + fb)
	for r in 0 .. reads_per_fb {
		mut s := Sig{}
		osal.ioc_acquire((core * 2 + fb * 3 + r) % nch, &s, u8(sizeof(s)))
		acc = acc * 1664525 + 1013904223 + s.v0 + s.v1 // representative compute
	}
	for w in 0 .. writes_per_fb {
		mut s := Sig{
			seq: acc
			v0:  acc
			v1:  acc ^ u32(w)
			v2:  acc + u32(w)
		}
		osal.ioc_publish(core * 2 + (w % 2), &s, u8(sizeof(s)))
	}
}

fn core_entry(core int, _ voidptr) {
	wall0 := osal.now_us()
	cpu0 := cpu_ns()
	deadline := wall0 + run_s * 1_000_000
	mut cycles := u64(0)
	mut ops := u64(0)
	for osal.now_us() < deadline {
		cstart := osal.now_us()
		if core == 0 {
			for bus in 0 .. buses_on_core0 {
				bridge_work(bus)
			}
			ops += u64(buses_on_core0) * u64(sigs_per_bus) * 2
		}
		for fb in 0 .. fbs_per_core {
			fb_work(core, fb)
		}
		ops += u64(fbs_per_core) * u64(reads_per_fb + writes_per_fb)
		cycles++
		next := cstart + cycle_us
		now := osal.now_us()
		if now < next {
			osal.sleep_us(next - now)
		}
	}
	cpu := cpu_ns() - cpu0
	wall := (osal.now_us() - wall0) * 1000
	mut sc := scratch()
	unsafe {
		sc[core * 4 + 0] = cpu
		sc[core * 4 + 1] = wall
		sc[core * 4 + 2] = cycles
		sc[core * 4 + 3] = ops
	}
}

fn main() {
	osal.ioc_shared_init() // shared IOC region BEFORE fork
	mut pids := []int{}
	for c in 0 .. cores {
		pids << osal.start_core(c, core_entry, unsafe { nil })
	}
	for p in pids {
		osal.wait_core(p)
	}

	mut sc := scratch()
	println('System load: ${cores} cores | ${buses_on_core0} CAN buses on core0 | ${fbs_per_core} FBs/core')
	println('  each FB: ${reads_per_fb} reads + ${writes_per_fb} writes per ${cycle_us / 1000}ms cycle, ${run_s}s run')
	println('  core  role              load    work/cycle   sig-ops/s')
	mut tot_ops := u64(0)
	for c in 0 .. cores {
		cpu := unsafe { sc[c * 4 + 0] }
		wall := unsafe { sc[c * 4 + 1] }
		cyc := unsafe { sc[c * 4 + 2] }
		ops := unsafe { sc[c * 4 + 3] }
		load := f64(cpu) / f64(wall) * 100.0
		work_us := f64(cpu) / f64(cyc) / 1000.0
		opss := f64(ops) * 1e9 / f64(wall) / 1e6
		role := if c == 0 { '8 buses + 50 FBs' } else { '50 FBs         ' }
		println('   ${c}    ${role}  ${load:5.2}%   ${work_us:7.1} us   ${opss:6.2} M/s')
		tot_ops += ops
	}
	tot_m := f64(tot_ops) / 1e6
	println('  total: ${tot_m:5.1} M signal ops over ${run_s}s')
}
