module app

import ports

// ButtonLamp: the whole app — mirror the button onto the LED.
pub struct ButtonLamp {
pub mut:
	lit bool
}

pub fn (mut fb ButtonLamp) on_10ms(inp ports.ButtonLampIn, mut out ports.ButtonLampOut) {
	fb.lit = inp.user_button.pressed
	out.led_green.on = fb.lit
}
