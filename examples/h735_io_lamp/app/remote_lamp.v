module app

import ports

// RemoteLamp: mirror the h755 node's button (BtnPressed, rx off ButtonState
// 0x310) onto this board's LD2 — the bus -> FB -> io output path of the
// cross-node demo. The FB is the mandatory middleman: io signals never go
// bus-to-pin (docs/io.md).
pub struct RemoteLamp {
pub mut:
	lit bool
}

pub fn (mut fb RemoteLamp) on_10ms(inp ports.RemoteLampIn, mut out ports.RemoteLampOut) {
	fb.lit = inp.btn_pressed.pressed
	out.led_remote.on = fb.lit
}
