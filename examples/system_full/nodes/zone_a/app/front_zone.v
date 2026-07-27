module app

import ports

pub struct FrontZoneCtrl {
pub mut:
	steering u32
}

pub fn (mut fb FrontZoneCtrl) on_50ms(inp ports.FrontZoneCtrlIn, mut out ports.FrontZoneCtrlOut) {
	// steering sweeps; a physical button press (PC13) jumps it hard — a real input
	// on this zone ECU driving a cross-node signal (SteeringAngle rides edge ->
	// gateway -> compute).
	if inp.user_button.pressed {
		fb.steering = 90
	} else {
		fb.steering = (fb.steering + 5) % 360
	}
	out.steering_angle.deg = fb.steering
	// the domain's HeadlightCmd (compute -> gateway -> here) drives a real LED (PB0):
	// a cross-node command reaching a physical pin.
	out.headlight_led.on = inp.headlight_cmd.mode != 0
}
