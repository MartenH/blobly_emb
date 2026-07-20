module app

import ports

// ButtonLamp: mirror the B1 button onto the green LED (local io round-trip) AND
// publish it as BtnPressed — the ONE cross-node signal (system.toml), carried as
// a u32 0/1 on ButtonState 0x310 (the target codec's trivial-u32@0 shape).
pub struct ButtonLamp {
pub mut:
	lit bool
}

pub fn (mut fb ButtonLamp) on_10ms(inp ports.ButtonLampIn, mut out ports.ButtonLampOut) {
	fb.lit = inp.user_button.pressed
	out.led_green.on = fb.lit
	out.btn_pressed.pressed = if fb.lit { u32(1) } else { u32(0) }
}
