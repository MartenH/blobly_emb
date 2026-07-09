module app

import ports

// Function blocks for the h735_app showcase — pure, portable handlers (no board or
// osal calls), so the SAME ecu.toml + FBs generate both a host/sim build and the
// bare-metal H735 target. Each is the usual shape: private state + a periodic handler
// that is a pure function of its input ports to its output ports.
//
// They exist to put a controllable, visible load on the core so the Loom's per-core
// load measurement (loom.Scheduler.load_permille) has something to report over CAN —
// watchable live in blobly_net.

// Governor emits a triangle-wave work command (LCG iteration count) so the synthetic
// load breathes up and down — in blobly_net you watch Load_Core0 rise and fall rather
// than sit flat. One step per 100 ms; a full sweep takes ~10 s, slow relative to the
// Loom's 1 s load-averaging window so the reported load tracks the command.
//
// Calibrated for a REALISTIC trace, not a saturated one: on the H735 (-Os) the load is
// linear at ~240k LCG iters per full 1 ms slot. iters_max = 96k keeps the Load handler
// at ≤~40 % of its slot, so the core sits at ≥60 % idle across the whole sweep — a
// healthy system, not a pegged one. The one anomaly is a periodic SPIKE injected by the
// Load handler (see below), not a sustained overload.
pub const iters_min = u32(48_000) // breathing floor: ~20 % of the 1 ms slot (~80 % idle)
pub const iters_max = u32(96_000) // breathing peak: ~40 % of the 1 ms slot (~60 % idle)
pub const iters_step = u32(2_000) // one step / 100 ms -> a slow, watchable sweep
pub const iters_spike = u32(132_000) // ~550 us: one slow run, just past the 500 us trace budget
pub const spike_every = u32(512) // inject the spike every ~512 Load runs (~0.5 s)

// Breathe between iters_min and iters_max (not down to 0), so the core stays a realistic
// 60–80 % idle across the whole sweep — a healthy busy system, never pegged, never dead.
pub struct Governor {
pub mut:
	iters  u32 = 48_000 // = iters_min: start mid-load, not idle
	rising bool = true
}

pub fn (mut g Governor) on_100ms(inp ports.GovernorIn, mut out ports.GovernorOut) {
	if g.rising {
		g.iters += iters_step
		if g.iters >= iters_max {
			g.iters = iters_max
			g.rising = false
		}
	} else {
		g.iters -= iters_step
		if g.iters <= iters_min {
			g.iters = iters_min
			g.rising = true
		}
	}
	out.load_cmd.iters = g.iters
}

// Load is a compute-bound FB: it burns the commanded number of LCG rounds, consuming a
// controllable slice of the core. That CPU time is exactly what the Loom accounts as
// processor load. Most runs stay well inside the 1 ms slot (≥60 % idle); every
// spike_every-th run injects a one-off ~550 us spike that exceeds [trace].trigger.
// budget_us, so the flight recorder has a realistic rare anomaly to freeze around —
// mostly-idle timeline with a single outlined overrun in the middle. The accumulator is
// published as Workload so the work is observed and the compiler can't elide the loop.
pub struct Load {
pub mut:
	acc u32 = 1
	n   u32
}

pub fn (mut l Load) on_1ms(inp ports.LoadIn, mut out ports.LoadOut) {
	l.n++
	mut iters := inp.load_cmd.iters
	if l.n % spike_every == 0 {
		iters = iters_spike // periodic overrun: the trace trigger fires here
	}
	mut a := l.acc
	for _ in 0 .. iters {
		a = a * 1664525 + 1013904223
	}
	l.acc = a
	out.workload.v = a
}

// Heartbeat is a cheap "I'm alive" FB — a periodic counter. Stands in for a real
// low-rate application handler and proves the schedule keeps ticking even while the
// Load FB is hammering the core.
pub struct Heartbeat {
pub mut:
	ticks u32
}

pub fn (mut h Heartbeat) on_100ms(inp ports.HeartbeatIn, mut out ports.HeartbeatOut) {
	h.ticks++
}
