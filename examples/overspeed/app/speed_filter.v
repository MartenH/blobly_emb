module app

import sig
import ports

// SpeedFilter (SENSE): smooths the raw bus speed.
pub struct SpeedFilter {
pub mut:
	last u16
}

pub fn (mut fb SpeedFilter) on_10ms(inp ports.SpeedFilterIn, mut out ports.SpeedFilterOut) {
	if inp.vehicle_speed.status == .ok {
		// +2 rounds so the IIR converges to the input (not truncates below it)
		fb.last = u16((u32(fb.last) * 3 + inp.vehicle_speed.kph + 2) / 4)
	}
	out.filtered_speed = sig.FilteredSpeed{
		kph:    fb.last
		status: inp.vehicle_speed.status // forwarded: the detector judges the SOURCE's freshness
	}
}
