module app

import ports

// Four pure-compute FBs across two partitions/cores, each burning a controllable number of LCG
// rounds so their timings are distinct and stable — the workload the per-core handler traces
// measure. `acc` persists in the partition state, so the work isn't optimised away and needs no
// output signal. SlowCtrl (core 1) glitches every 40th run to blow its budget and fire that
// core's ring trigger, so a dump shows the window around the anomaly — on core 1's block, while
// core 0 keeps its own independent ring.

fn burn(acc u32, rounds u32) u32 {
	mut a := acc
	for _ in 0 .. rounds {
		a = a * 1664525 + 1013904223
	}
	return a
}

// --- core 0: the sense partition ---

pub struct FastSense {
pub mut:
	acc u32 = 1
}

pub fn (mut fb FastSense) on_5ms(inp ports.FastSenseIn, mut out ports.FastSenseOut) {
	fb.acc = burn(fb.acc, 3_000)
}

pub struct MedSense {
pub mut:
	acc u32 = 1
}

pub fn (mut fb MedSense) on_10ms(inp ports.MedSenseIn, mut out ports.MedSenseOut) {
	fb.acc = burn(fb.acc, 30_000)
}

// --- core 1: the ctrl partition ---

pub struct CtrlWork {
pub mut:
	acc u32 = 1
}

pub fn (mut fb CtrlWork) on_10ms(inp ports.CtrlWorkIn, mut out ports.CtrlWorkOut) {
	fb.acc = burn(fb.acc, 60_000)
}

pub struct SlowCtrl {
pub mut:
	acc u32 = 1
	n   u32
}

pub fn (mut fb SlowCtrl) on_20ms(inp ports.SlowCtrlIn, mut out ports.SlowCtrlOut) {
	fb.n++
	// Every 40th run is a glitch: ~20x the work, reliably over the trace trigger budget so
	// core 1's ring freezes and a dump shows the window around it.
	fb.acc = burn(fb.acc, if fb.n % 40 == 0 { u32(2_400_000) } else { u32(120_000) })
}
