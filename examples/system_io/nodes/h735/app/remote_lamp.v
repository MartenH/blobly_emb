module app

import ports

// RemoteLamp: mirror the h755 node's button (BtnPressed, rx off ButtonState 0x310)
// onto this board's LED. io never goes bus-to-pin — the FB is the middleman.
pub struct RemoteLamp {
pub mut:
	lit bool
}

pub fn (mut fb RemoteLamp) on_10ms(inp ports.RemoteLampIn, mut out ports.RemoteLampOut) {
	fb.lit = inp.btn_pressed.pressed != 0
	out.led_remote.on = fb.lit
}
