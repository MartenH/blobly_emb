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

// SteerLimiter reads the LOCAL RawSteer (from the sensor, same thread) and clamps it to a
// speed-dependent maximum before it goes on the wire as SteeringAngle — a toy "speed-sensitive
// steering". VehicleSpeed and HeadlightCmd arrive via the gateway from domain; the clamp uses
// the speed (HeadlightCmd is received but this toy doesn't act on it).
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
	out.steering_angle.deg = deg
}
