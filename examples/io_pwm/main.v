module main

import gen

fn main() {
	println('io_pwm: io@c0 (Pot PA3 adc -> FanDuty PE9 pwm) | app@c0 Dimmer')
	gen.run()
}
