module app

import sig
import ports

// LampController (CTRL): drives the warning lamp.
pub struct LampController {
pub mut:
	on bool
}

pub fn (mut fb LampController) on_10ms(inp ports.LampControllerIn, mut out ports.LampControllerOut) {
	fb.on = inp.overspeed.active || inp.high_rev.active
	out.warn_lamp = sig.WarnLamp{
		on: fb.on
	}
	// also publish the lamp state on a SecOC-authenticated frame
	out.secure_status = sig.SecureStatus{
		level: if fb.on { u8(1) } else { u8(0) }
	}
}
