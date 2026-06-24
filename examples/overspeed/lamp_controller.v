module main

// LampController (CTRL): drives the warning lamp.
// reads Overspeed (across cores) + HighRev (local) -> writes WarnLamp (CAN/COM).
pub struct LampController {
pub mut:
	on bool
}

pub fn (mut fb LampController) on_10ms(inp LampControllerIn, mut out LampControllerOut) {
	fb.on = inp.overspeed.active || inp.high_rev.active
	out.warn_lamp = WarnLamp{
		on: fb.on
	}
}
