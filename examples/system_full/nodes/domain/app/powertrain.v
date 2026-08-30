module app

import ports

pub struct PowertrainCtrl {
pub mut:
	ticks u32
	acc   u32 = 1
}

pub fn (mut fb PowertrainCtrl) on_50ms(inp ports.PowertrainCtrlIn, mut out ports.PowertrainCtrlOut) {
	fb.ticks++
	// a bounded control burn so the CM7 (Core0) shows a non-zero load too (~0.8 ms at 400 MHz,
	// sub-tick; the comm thread's own work is separate and not counted in this FB-thread load).
	mut a := fb.acc
	for _ in 0 .. 320_000 {
		a = a * 1664525 + 1013904223
	}
	fb.acc = a
	// VehicleSpeed folds in the CM4 co-processor's TorqueEstimate — a value produced on the OTHER
	// core, read here via the xioc seam (layout-gated). Before the satellite is up it reads 0.
	out.vehicle_speed.kph = u32(60 + (fb.ticks % 40) + (inp.torque_estimate.nm % 20))
	// headlights on when "steering hard" (a toy cross-bus reaction: SteeringAngle rides
	// edge -> gateway -> compute, so this closes the loop through the H735 router)
	out.headlight_cmd.mode = if inp.steering_angle.deg > 90 { u32(1) } else { u32(0) }
	// LedLevel: a 0.5 Hz triangle (40 ticks of 50 ms = 2 s period, 0..1000 permille) that
	// zone_a puts on its red LED as PWM intensity — a cross-node signal you can watch fade.
	ph := fb.ticks % 40
	out.led_level.permille = if ph < 20 { ph * 50 } else { (40 - ph) * 50 }
	// DriveMode: a persisted calibration — step it slowly so the NvM journal is exercised and
	// the value survives resets. Restored before this first runs; FB just does "something".
	mut m := inp.drive_mode.mode
	if fb.ticks % 200 == 0 {
		m = (m + 1) % 4
	}
	out.drive_mode.mode = m
}
