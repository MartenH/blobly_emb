module app

import sig

// A Function Block (FB): private state + a periodic handler that is a pure
// function of its input signals to its output signals. It knows nothing about
// buses, cores or IOC — the Loom snapshots inputs in, publishes outputs out.
// The In/Out port structs are generated from ecu.toml (sig/ports_gen.v).

pub struct SpeedMonitor {
pub mut:
	over_limit bool
}

// on_10ms runs every 10 ms: raise the lamp when speed exceeds the limit.
pub fn (mut fb SpeedMonitor) on_10ms(inp sig.SpeedMonitorIn, mut out sig.SpeedMonitorOut) {
	fb.over_limit = inp.vehicle_speed.valid && inp.vehicle_speed.kph > 120
	out.warn_lamp.on = fb.over_limit
}
