module app

// The CM4 "dynamics" co-processor FB (system_full domain satellite). It burns a bounded LCG
// window (so the CM4 shows a REAL load in the cross-core CpuLoad frame) and publishes the result
// as TorqueEstimate — a CROSS-CORE signal the CM7 control loop reads. The point is the cross-core
// paths (load telemetry, the bulk model-stream, and now the signal into the loop), not real dynamics.

import ports

pub struct DynamicsModel {
pub mut:
	ticks u32
	acc   u32 = 1
}

pub fn (mut fb DynamicsModel) on_5ms(inp ports.DynamicsModelIn, mut out ports.DynamicsModelOut) {
	fb.ticks++
	// ~0.8 ms at 200 MHz on a 5 ms period => ~15% steady CM4 load (sub-tick, so no overrun);
	// bulkperf's burst pushes the core toward 100% on top of this.
	mut a := fb.acc
	for _ in 0 .. 10_000 {
		a = a * 1664525 + 1013904223
	}
	fb.acc = a
	// publish the estimate cross-core (xioc slot) — the CM7 PowertrainCtrl reads it. This is also
	// the observable sink that keeps the burn from being dead-code-eliminated (no __global needed).
	out.torque_estimate.nm = a % 500
}
