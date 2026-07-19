module app

import ports

// Dimmer: map a 12-bit pot (0..4095) to a PWM duty in permille (0..1000).
pub struct Dimmer {
pub mut:
	duty u16
}

pub fn (mut fb Dimmer) on_10ms(inp ports.DimmerIn, mut out ports.DimmerOut) {
	fb.duty = u16(u32(inp.pot.count) * 1000 / 4095)
	out.fan_duty.duty = fb.duty
}
