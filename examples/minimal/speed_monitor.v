module main

// SpeedMonitor: the whole app — raise the lamp above 120 km/h.
pub struct SpeedMonitor {
pub mut:
	over_limit bool
}

pub fn (mut fb SpeedMonitor) on_10ms(inp SpeedMonitorIn, mut out SpeedMonitorOut) {
	fb.over_limit = inp.vehicle_speed.valid && inp.vehicle_speed.kph > 120
	out.warn_lamp.on = fb.over_limit
}
