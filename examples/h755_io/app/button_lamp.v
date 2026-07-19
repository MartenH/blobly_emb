module app

import ports

// ButtonLamp: mirror the user button onto the green LED — the io input -> FB ->
// io output round trip, observable with one finger on B1 — and publish the same
// value as BtnPressed (ButtonState on the bus): the tx half of the cross-node
// button demo (examples/h735_io_lamp mirrors it onto its own LED).
pub struct ButtonLamp {
pub mut:
	lit bool
}

pub fn (mut fb ButtonLamp) on_10ms(inp ports.ButtonLampIn, mut out ports.ButtonLampOut) {
	fb.lit = inp.user_button.pressed
	out.led_green.on = fb.lit
	out.btn_pressed.pressed = fb.lit
}
