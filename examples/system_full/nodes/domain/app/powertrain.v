module app

import ports

pub struct PowertrainCtrl {
pub mut:
	ticks u32
}

pub fn (mut fb PowertrainCtrl) on_50ms(inp ports.PowertrainCtrlIn, mut out ports.PowertrainCtrlOut) {
	fb.ticks++
	// the CM4 co-processor's torque estimate (cross-core xioc) nudges the speed calc — the
	// point is that a value produced on the OTHER core reaches this control loop.
	out.vehicle_speed.kph = u32(60 + (fb.ticks % 40) + (inp.torque_estimate.nm % 8))
	// headlights on when "steering hard" (a toy cross-bus reaction: SteeringAngle rides
	// edge -> gateway -> compute, so this closes the loop through the H735 router)
	out.headlight_cmd.mode = if inp.steering_angle.deg > 90 { u32(1) } else { u32(0) }
	// DriveMode: a persisted calibration — step it slowly so the NvM journal is exercised and
	// the value survives resets. Restored before this first runs; FB just does "something".
	mut m := inp.drive_mode.mode
	if fb.ticks % 200 == 0 {
		m = (m + 1) % 4
	}
	out.drive_mode.mode = m
}
