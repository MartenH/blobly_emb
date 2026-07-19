module app

import ports

// Sweep: the no-pot analog bench. The PWM duty SELF-RAMPS as a triangle from a
// free-running tick counter — 0..1000..0 over ~4 s at the 10 ms handler period
// (200 steps each way) — so the PE9 scope trace visibly sweeps its pulse width
// with nothing wired to the analog input (P3, io.pwm out). Independently, the
// pot count read on PA3 is mirrored to the bus (PotLevel) and lights LedHi past
// mid-scale (P2, io.adc in) — jumper PA3 to a rail to exercise the ADC path.
const ramp_top = u16(1000) // permille full-scale
const ramp_step = u16(5)   // 200 ticks (2 s) per edge -> ~4 s triangle
const adc_mid = u16(2048)  // 12-bit half-scale

pub struct Sweep {
pub mut:
	duty u16
	down bool
}

pub fn (mut fb Sweep) on_10ms(inp ports.SweepIn, mut out ports.SweepOut) {
	// triangle ramp for the PWM out — self-driving, no input needed.
	if fb.down {
		if fb.duty <= ramp_step {
			fb.duty = 0
			fb.down = false
		} else {
			fb.duty -= ramp_step
		}
	} else {
		if fb.duty + ramp_step >= ramp_top {
			fb.duty = ramp_top
			fb.down = true
		} else {
			fb.duty += ramp_step
		}
	}
	out.fan_duty.duty = fb.duty

	// analog IN mirrored out: raw count onto the bus + a mid-scale LED.
	out.pot_level.level = u32(inp.pot.count)
	out.led_hi.on = inp.pot.count >= adc_mid
}
