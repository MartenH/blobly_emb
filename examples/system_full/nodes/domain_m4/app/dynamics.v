module app

// The CM4 "dynamics" co-processor FB (system_full domain satellite). It just produces a
// moving TorqueEstimate so the cross-core signal is live and the CM7 control loop has
// something from the other core to read — the FB body is deliberately trivial (the point is
// the cross-core path + the bulk model-stream, not real vehicle dynamics).

import ports

pub struct DynamicsModel {
pub mut:
	ticks u32
}

pub fn (mut fb DynamicsModel) on_5ms(inp ports.DynamicsModelIn, mut out ports.DynamicsModelOut) {
	fb.ticks++ // self-contained co-processor "work"; the cross-core payload is the bulk stream
}
