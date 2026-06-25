module app

import sig
import ports

// OverspeedDetector (SENSE): threshold on the filtered speed.
pub struct OverspeedDetector {
pub mut:
	active bool
}

pub fn (mut fb OverspeedDetector) on_10ms(inp ports.OverspeedDetectorIn, mut out ports.OverspeedDetectorOut) {
	fb.active = inp.filtered_speed.valid && inp.filtered_speed.kph > 120
	out.overspeed = sig.Overspeed{
		active: fb.active
	}
}
