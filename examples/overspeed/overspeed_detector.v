module main

// OverspeedDetector (SENSE): threshold on the filtered speed.
// reads FilteredSpeed (local, same core) -> writes Overspeed (across cores to ctrl).
pub struct OverspeedDetector {
pub mut:
	active bool
}

pub fn (mut fb OverspeedDetector) on_10ms(inp OverspeedDetectorIn, mut out OverspeedDetectorOut) {
	fb.active = inp.filtered_speed.valid && inp.filtered_speed.kph > 120
	out.overspeed = Overspeed{
		active: fb.active
	}
}
