module app

import ports

// SpeedWork reads VehicleSpeed (delivered by the can0 comm bridge over IOC) and burns a
// controllable number of LCG rounds — a stable workload the trace measures. Every 40th run
// glitches (~20x) to blow the trigger budget so the ring freezes and a dump shows the window;
// the point of this example is that the can0 COMM thread's own work shows up as its own lane.
fn burn(acc u32, rounds u32) u32 {
	mut a := acc
	for _ in 0 .. rounds {
		a = a * 1664525 + 1013904223
	}
	return a
}

pub struct SpeedWork {
pub mut:
	acc u32 = 1
	n   u32
}

pub fn (mut fb SpeedWork) on_10ms(inp ports.SpeedWorkIn, mut out ports.SpeedWorkOut) {
	fb.n++
	// fold the received speed in so the read isn't optimised away
	fb.acc += u32(inp.vehicle_speed.kph)
	fb.acc = burn(fb.acc, if fb.n % 40 == 0 { u32(2_400_000) } else { u32(120_000) })
}
