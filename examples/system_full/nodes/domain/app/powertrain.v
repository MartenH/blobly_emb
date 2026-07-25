module app

import ports

pub struct PowertrainCtrl {
pub mut:
	ticks u32
}

pub fn (mut fb PowertrainCtrl) on_50ms(inp ports.PowertrainCtrlIn, mut out ports.PowertrainCtrlOut) {
	fb.ticks++
	out.vehicle_speed.kph = u32(60 + (fb.ticks % 40))
	// headlights on when "steering hard" (a toy cross-bus reaction: SteeringAngle rides
	// edge -> gateway -> compute, so this closes the loop through the H735 router)
	out.headlight_cmd.mode = if inp.steering_angle.deg > 90 { u32(1) } else { u32(0) }
}
