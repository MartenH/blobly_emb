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
	max := if inp.vehicle_speed.kph > 90 { u32(180) } else { u32(360) }
	mut deg := inp.raw_steer.deg
	if deg > max {
		deg = max
	}
	// a physical button press (PC13) forces a hard steer — a real input on this zone ECU
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

// safety_level_max: the most a SafetyCmd level may be (compute.dbc / edge.dbc range)
const safety_level_max = u16(1000)

// SafetyMonitor acts on the tester's protected SafetyCmd only while its receive status is ok —
// never received, timed out or corrupt, it holds the safe level 0 (docs/diagnostics.md §3.2: the
// FB sees the status beside the value and chooses its reaction). It reports what it saw on
// SafetyView: byte 0 the status, byte 1 the lost-frame count (wrapping), bytes 2-3 the level acted on.
pub struct SafetyMonitor {
pub mut:
	level u16
}

pub fn (mut fb SafetyMonitor) on_50ms(inp ports.SafetyMonitorIn, mut out ports.SafetyMonitorOut) {
	fb.level = if inp.safety_cmd.status == .ok && inp.safety_cmd.level <= safety_level_max {
		inp.safety_cmd.level
	} else {
		0
	}
	out.safety_view.code = u32(inp.safety_cmd.status) | ((inp.safety_cmd.lost & 0xFF) << 8) | (u32(fb.level) << 16)
}
