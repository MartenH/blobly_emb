module app

import ports

// HostBreather is the tester's one job: a 0.5 Hz triangle (20 ticks of 100 ms = 2 s period,
// 0..1000 permille) on HostLedLevel. The domain puts it on its red LD3 as PWM intensity —
// the mirror of the domain's own LedLevel, which zone_a puts on ITS LD3 through the gateway.
pub struct HostBreather {
pub mut:
	ticks u32
}

pub fn (mut fb HostBreather) on_100ms(_ ports.HostBreatherIn, mut out ports.HostBreatherOut) {
	fb.ticks++
	ph := fb.ticks % 20
	out.host_led_level.permille = if ph < 10 { ph * 100 } else { (20 - ph) * 100 }
}
