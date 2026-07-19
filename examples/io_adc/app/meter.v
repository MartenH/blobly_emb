module app

import ports

// Meter: light LedHi when the analog input crosses mid-scale (a 12-bit ADC
// reads 0..4095; 2048 is the midpoint). The raw count is the signal — scaling
// to volts is the app's business, above the driver (REQ-IO-019).
pub struct Meter {
pub mut:
	hi bool
}

pub fn (mut fb Meter) on_10ms(inp ports.MeterIn, mut out ports.MeterOut) {
	fb.hi = inp.pot_volt.count > 2048
	out.led_hi.on = fb.hi
}
