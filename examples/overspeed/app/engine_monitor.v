module app

import sig
import ports

// EngineMonitor (CTRL): flags high engine revs.
pub struct EngineMonitor {
pub mut:
	high bool
}

pub fn (mut fb EngineMonitor) on_10ms(inp ports.EngineMonitorIn, mut out ports.EngineMonitorOut) {
	fb.high = inp.engine_speed.valid && inp.engine_speed.rpm > 4000
	out.high_rev = sig.HighRev{
		active: fb.high
	}
}
