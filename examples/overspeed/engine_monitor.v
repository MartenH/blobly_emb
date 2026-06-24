module main

// EngineMonitor (CTRL): flags high engine revs.
// reads EngineSpeed (CAN/COM) -> writes HighRev (local, same core).
pub struct EngineMonitor {
pub mut:
	high bool
}

pub fn (mut fb EngineMonitor) on_10ms(inp EngineMonitorIn, mut out EngineMonitorOut) {
	fb.high = inp.engine_speed.valid && inp.engine_speed.rpm > 4000
	out.high_rev = HighRev{
		active: fb.high
	}
}
