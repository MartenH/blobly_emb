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

// safety_level_max: the most a SafetyCmd level may be (its range in edge.dbc)
const safety_level_max = u16(1000)

// SafetyMonitor acts on the chassis node's protected SafetyCmd only while its receive status is ok —
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

// calibration_dispatches: how many dispatches SensorCalibration runs before it is done (5 s at 50 ms)
const calibration_dispatches = u16(100)

// RoutineRunner runs zone_a's two routines (RoutineControl 0x31, ecu.toml; docs/diagnostics.md §3.1):
// the request of each arrives as an op in exactly one dispatch, and what it writes into each result is
// what the diagnostic server answers. Every op is answered, a stop the server issues itself (a timeout,
// the session ending) included.
//   ActuatorSelfTest (sync): option N runs N steps of 100 ms — 2N dispatches — then done, the count of
//     dispatches its record (u16 big-endian); option 0 is refused (requestOutOfRange).
//   SensorCalibration (async): running from its start, the count rising every dispatch so 0x31 03
//     sees it move; done after calibration_dispatches, stopped by a stop.
pub struct RoutineRunner {
pub mut:
	test_left u32 // self-test dispatches still to run (0 = idle)
	test_n    u16
	cal_on    bool
	cal_n     u16
}

pub fn (mut fb RoutineRunner) on_50ms(inp ports.RoutineRunnerIn, mut out ports.RoutineRunnerOut) {
	fb.self_test(inp, mut out)
	fb.calibration(inp, mut out)
}

fn (mut fb RoutineRunner) self_test(inp ports.RoutineRunnerIn, mut out ports.RoutineRunnerOut) {
	match inp.actuator_self_test_request.op {
		.start {
			steps := u32(inp.actuator_self_test_request.option[0])
			if steps == 0 {
				out.actuator_self_test_result.state = .refused
				out.actuator_self_test_result.nrc = 0x31
				return
			}
			fb.test_left = 2 * steps
			fb.test_n = 0
		}
		.stop {
			fb.test_left = 0
			out.actuator_self_test_result.state = .stopped
			put_u16(mut out.actuator_self_test_result.record, fb.test_n)
			return
		}
		else {}
	}
	if fb.test_left == 0 {
		return // idle: the last report stands
	}
	fb.test_n++
	fb.test_left--
	out.actuator_self_test_result.state = if fb.test_left == 0 { .done } else { .running }
	put_u16(mut out.actuator_self_test_result.record, fb.test_n)
}

fn (mut fb RoutineRunner) calibration(inp ports.RoutineRunnerIn, mut out ports.RoutineRunnerOut) {
	match inp.sensor_calibration_request.op {
		.start {
			fb.cal_on = true
			fb.cal_n = 0
		}
		.stop {
			fb.cal_on = false // answered stopped even when idle: every op is answered
			out.sensor_calibration_result.state = .stopped
			put_u16(mut out.sensor_calibration_result.record, fb.cal_n)
			return
		}
		else {}
	}
	if !fb.cal_on {
		return
	}
	fb.cal_n++
	if fb.cal_n >= calibration_dispatches {
		fb.cal_on = false
	}
	out.sensor_calibration_result.state = if fb.cal_on { .running } else { .done }
	put_u16(mut out.sensor_calibration_result.record, fb.cal_n)
}

// put_u16: a count into a 2-byte record, big-endian
fn put_u16(mut rec [2]u8, v u16) {
	rec[0] = u8(v >> 8)
	rec[1] = u8(v)
}
