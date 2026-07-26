module app

// The CM4 "dynamics" co-processor FB (system_full domain satellite). It burns a bounded LCG
// window so the CM4 shows a REAL processor load in the cross-core CpuLoad frame (Core1) — the
// point is the cross-core paths (load telemetry + the bulk model-stream), not real dynamics.

import ports

// A module global the burn result escapes into. Without an OBSERVABLE sink, V's dead-code
// elimination drops a loop whose result never leaves the FB, and the CM4 reads 0% load. A
// __global write is external state V never eliminates. (No default value: a __global field
// default is the _vinit-trap, see scripts/lint_vinit.sh.)
__global (
	g_dyn_sink u32
)

pub struct DynamicsModel {
pub mut:
	ticks u32
	acc   u32 = 1
}

pub fn (mut fb DynamicsModel) on_5ms(inp ports.DynamicsModelIn, mut out ports.DynamicsModelOut) {
	fb.ticks++
	// ~0.6 ms at 200 MHz on a 5 ms period => ~12% steady CM4 load (sub-tick, so no overrun);
	// bulkperf's burst pushes the core toward 100% on top of this.
	mut a := fb.acc
	for _ in 0 .. 10_000 { // ~0.8 ms at 200 MHz => ~15% at a 5 ms period, sub-tick (no overrun)
		a = a * 1664525 + 1013904223
	}
	fb.acc = a
	g_dyn_sink = a // observable sink: keeps the burn from being optimized away
}
