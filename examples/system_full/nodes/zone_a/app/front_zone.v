module app

import ports

// SteerSensor sweeps a raw steering angle and publishes it on the node-local RawSteer signal.
// It has no inputs — the underscore marks `inp` deliberately unused.
pub struct SteerSensor {
pub mut:
	raw u32
}

pub fn (mut fb SteerSensor) on_50ms(_ ports.SteerSensorIn, mut out ports.SteerSensorOut) {
	fb.raw = (fb.raw + 5) % 360
	out.raw_steer.deg = fb.raw
}

// speed_plausible_kph: the most a vehicle speed can be; above it the value is implausible.
const speed_plausible_kph = u32(250)

// SteerLimiter reads the LOCAL RawSteer (from the sensor, same thread) and clamps it to a
// speed-dependent maximum before it goes on the wire as SteeringAngle — a toy "speed-sensitive
// steering". VehicleSpeed and HeadlightCmd arrive via the gateway from domain. Physical IO
// (docs/io.md): a button press forces a hard steer, and HeadlightCmd drives a real LED.
pub struct SteerLimiter {
pub mut:
	ticks u32
}

pub fn (mut fb SteerLimiter) on_50ms(inp ports.SteerLimiterIn, mut out ports.SteerLimiterOut) {
	fb.ticks++
	mut max := if inp.vehicle_speed.kph > 90 { u32(180) } else { u32(360) }
	// the vehicle's coded limit (a parameter: read-only here, coded by a tester with 0x2E)
	if u32(inp.steer_limit.deg) < max {
		max = u32(inp.steer_limit.deg)
	}
	mut deg := inp.raw_steer.deg
	if deg > max {
		deg = max
	}
	// a physical button press (PC13) forces a hard steer (past the coded limit: a test input) — a real input on this zone ECU
	// driving a cross-node signal (SteeringAngle rides edge -> gateway -> compute). 180 is
	// ABOVE the domain's headlight threshold (PowertrainCtrl asserts HeadlightCmd on
	// steering > 90) and within the tighter speed clamp, so a press closes the loop and
	// lights the LED via HeadlightCmd.
	if inp.user_button.pressed {
		deg = 180
	}
	out.steering_angle.deg = deg
	// the received speed's plausibility, the CURRENT result every dispatch (no latch: the fault
	// memory keeps the history, docs/diagnostics.md §3.3) — DTC U0401-00 on this node
	out.fault.speed_implausible = if inp.vehicle_speed.kph > speed_plausible_kph {
		.failed
	} else {
		.passed
	}
	// the domain's HeadlightCmd (compute -> gateway -> here) drives a real LED (PB0):
	// a cross-node command reaching a physical pin.
	out.headlight_led.on = inp.headlight_cmd.mode != 0
	// the domain's LedLevel (0..1000 permille, a 0.5 Hz triangle) drives LD3 (PB14) as PWM
	// duty: a cross-node signal you can watch fade on the pin.
	out.breath_led.duty = inp.led_level.permille
}
