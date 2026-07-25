module app

import ports

pub struct RearBodyCtrl {
pub mut:
	temp u32 = 22
}

pub fn (mut fb RearBodyCtrl) on_100ms(inp ports.RearBodyCtrlIn, mut out ports.RearBodyCtrlOut) {
	out.ambient_temp.celsius = fb.temp
	out.tailgate_status.open = if inp.brake_state.pressed != 0 { u32(0) } else { u32(1) }
}
