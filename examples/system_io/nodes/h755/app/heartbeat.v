module app

import ports

// Heartbeat: toggle the yellow LED every activation (500 ms period -> 1 Hz blink) —
// the io output path is bench-observable without pressing anything.
pub struct Heartbeat {
pub mut:
	on bool
}

pub fn (mut fb Heartbeat) on_500ms(inp ports.HeartbeatIn, mut out ports.HeartbeatOut) {
	fb.on = !fb.on
	out.led_yellow.on = fb.on
}
