module app

import ports

pub struct FrontZoneCtrl {
pub mut:
	steering u32
}

pub fn (mut fb FrontZoneCtrl) on_50ms(inp ports.FrontZoneCtrlIn, mut out ports.FrontZoneCtrlOut) {
	fb.steering = (fb.steering + 5) % 360
	out.steering_angle.deg = fb.steering
}
