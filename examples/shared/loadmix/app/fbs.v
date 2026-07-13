module app

import ports

// The SHARED demo app (examples/shared/loadmix): h735_threadx and h755_threadx run this
// same mixed-rate load — one source instead of two byte-identical copies drifting apart.
// Each example's Makefile adds this directory to the V module path; the per-board ports/
// sig modules still come from the example's own generated files. NOTE: each example's
// ports module must declare the same FB In/Out shapes (they do — same ecu.toml FB set);
// the iteration calibration below was measured on the H735 at 550 MHz (the H755 runs the
// same budgets slower — still far from overrun).
//
// A "realistic" mixed-rate load for the multi-thread ThreadX target: three FB threads at
// rate-monotonic priorities (fast 10 ms > mid 20 ms > slow 100 ms, comm above all of them),
// so the trace's swimlane shows real preemption — the fast thread cutting into the mid/slow
// burns, comm cutting into everything when a frame arrives.
//
// Calibrated against THIS image's MEASURED throughput: ~183k LCG iters per ms (bench, FB trace
// lane: burn(45k) -> 246 us — the standalone burn() compiles ~10x tighter than the old inline
// loop, so calibrate against what the trace MEASURES, not what a previous image did). Budgets:
//   fast : ~2.5 ms per 10 ms  (~25 %)  + a ~5.5 ms spike every ~0.6 s (the visible outlier)
//   mid  : ~3.0 ms per 20 ms  (~15 %)
//   slow : 1..4 ms per 100 ms (~1-4 %) — the Governor-swept, CAN-commandable burn
// Total ~45 % with clear idle — half the core busy, half visibly free.
pub const fast_iters = u32(450_000) // ~2.5 ms of a 10 ms period
pub const fast_spike = u32(1_000_000) // ~5.5 ms: blows the period every spike_every runs
pub const spike_every = u32(64) // one spike per ~0.6 s of fast runs
pub const mid_iters = u32(550_000) // ~3 ms of a 20 ms period
pub const slow_min = u32(180_000) // sweep floor: ~1 ms per 100 ms
pub const slow_max = u32(730_000) // sweep peak: ~4 ms per 100 ms
pub const slow_step = u32(20_000) // one step / 100 ms -> a slow, watchable sweep

// burn spins the LCG `iters` times and returns the accumulator, so the work is observable
// and the compiler can't elide the loop.
fn burn(seed u32, iters u32) u32 {
	mut a := seed
	for _ in 0 .. iters {
		a = a * 1664525 + 1013904223
	}
	return a
}

// LoadFast: the 10 ms high-priority worker — it preempts everything below it. Every
// spike_every-th run injects the one-off overrun the flight recorder exists to catch.
pub struct LoadFast {
pub mut:
	acc u32 = 1
	n   u32
}

pub fn (mut l LoadFast) on_10ms(inp ports.LoadFastIn, mut out ports.LoadFastOut) {
	l.n++
	mut iters := fast_iters
	if l.n % spike_every == 0 {
		iters = fast_spike
	}
	l.acc = burn(l.acc, iters)
}

// LoadMid: the 20 ms mid-priority worker — visibly sliced by LoadFast and comm.
pub struct LoadMid {
pub mut:
	acc u32 = 1
}

pub fn (mut l LoadMid) on_20ms(inp ports.LoadMidIn, mut out ports.LoadMidOut) {
	l.acc = burn(l.acc, mid_iters)
}

// Governor: the 100 ms low-priority controller — sweeps the slow burn between slow_min and
// slow_max so the total load breathes; a host command (bus -> comm -> rx IOC -> here)
// overrides the sweep, clamped to a safe range. code == 0 means "no command" -> sweep.
pub struct Governor {
pub mut:
	iters  u32 = 180_000 // = slow_min
	rising bool = true
}

pub fn (mut g Governor) on_100ms(inp ports.GovernorIn, mut out ports.GovernorOut) {
	if inp.command.code != 0 {
		mut c := inp.command.code
		if c < slow_min {
			c = slow_min
		}
		if c > slow_max {
			c = slow_max
		}
		g.iters = c
	} else if g.rising {
		g.iters += slow_step
		if g.iters >= slow_max {
			g.iters = slow_max
			g.rising = false
		}
	} else {
		g.iters -= slow_step
		if g.iters <= slow_min {
			g.iters = slow_min
			g.rising = true
		}
	}
	out.load_cmd.iters = g.iters
}

// LoadSlow: the 100 ms low-priority burn (same thread as the Governor, so LoadCmd stays a
// plain local cell — cross-thread signals are the IOC's job). Publishes its accumulator as
// Workload so the work is observed on the bus.
pub struct LoadSlow {
pub mut:
	acc u32 = 1
}

pub fn (mut l LoadSlow) on_100ms(inp ports.LoadSlowIn, mut out ports.LoadSlowOut) {
	l.acc = burn(l.acc, inp.load_cmd.iters)
	out.workload.v = l.acc
}
