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
// load ramps up and back down — in blobly_net you watch Load_Core0 breathe rather than
// sit flat. One step per 100 ms; a full sweep takes ~12 s, slow relative to the Loom's
// 1 s load-averaging window so the reported load tracks the command across its range.
// The load is linear in iters (measured on the H735, generated code -Os): ~24k -> 10 %,
// ~100k -> 40 % of the 1 ms slot, so a full slot is ~240k iters. iters_max deliberately
// peaks well past that, so the top of the triangle drives the Load handler past its
// 1 ms slot and the demo exercises overrun handling: the 1 s window breathes up and
// saturates, the 100 ms window spikes to 100 % near the peak, and the Loom's overrun
// counter climbs — all shown in the 0x7E1 LoadDetail frame. Drop iters_max to ~120k for
// a pure in-budget breathing curve (peaks ~50 %, never overruns).
pub const iters_max = u32(320_000)
pub const iters_step = u32(4_000)

pub struct Governor {
pub mut:
	iters  u32
	rising bool = true
}

pub fn (mut g Governor) on_100ms(inp ports.GovernorIn, mut out ports.GovernorOut) {
	if g.rising {
		g.iters += iters_step
		if g.iters >= iters_max {
			g.iters = iters_max
			g.rising = false
		}
	} else if g.iters <= iters_step {
		g.iters = 0
		g.rising = true
	} else {
		g.iters -= iters_step
	}
	out.load_cmd.iters = g.iters
}

// Load is a compute-bound FB: it burns the commanded number of LCG rounds, consuming a
// controllable slice of the core. That CPU time is exactly what the Loom accounts as
// processor load. The accumulator is published as Workload so the work is observed and
// the compiler can't optimise the loop away.
pub struct Load {
pub mut:
	acc u32 = 1
}

pub fn (mut l Load) on_1ms(inp ports.LoadIn, mut out ports.LoadOut) {
	mut a := l.acc
	for _ in 0 .. inp.load_cmd.iters {
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
