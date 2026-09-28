module app

import sig
import ports

// EngineMonitor (CTRL): flags high engine revs, and tests for an over-rev fault — reporting the
// CURRENT result each dispatch; debounce, DTC status and clearing are the platform's.
pub struct EngineMonitor {
pub mut:
	high bool
}

pub fn (mut fb EngineMonitor) on_10ms(inp ports.EngineMonitorIn, mut out ports.EngineMonitorOut) {
	fb.high = inp.engine_speed.status == .ok && inp.engine_speed.rpm > 4000
	out.high_rev = sig.HighRev{
		active: fb.high
	}
	out.fault.engine_over_rev = if inp.engine_speed.status != .ok {
		.not_tested // no trustworthy speed: no verdict
	} else if inp.engine_speed.rpm > 6000 {
		.failed
	} else {
		.passed
	}
	out.fault.engine_idle_low = if inp.engine_speed.status != .ok {
		.not_tested
	} else if inp.engine_speed.rpm < 400 {
		.failed
	} else {
		.passed
	}
}
