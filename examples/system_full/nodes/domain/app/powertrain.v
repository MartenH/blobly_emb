module app

import ports

pub struct PowertrainCtrl {
pub mut:
	ticks u32
}

pub fn (mut fb PowertrainCtrl) on_50ms(inp ports.PowertrainCtrlIn, mut out ports.PowertrainCtrlOut) {
	fb.ticks++
	out.vehicle_speed.kph = u32(60 + (fb.ticks % 40))
	out.engine_rpm.rpm = u32(2000 + (fb.ticks % 1000))
	out.brake_state.pressed = if inp.steering_angle.deg > 90 { u32(1) } else { u32(0) }
	out.headlight_cmd.mode = u32(1)
	out.hvac_cmd.temp = u32(21)
}
