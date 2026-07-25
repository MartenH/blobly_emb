module app

import ports

pub struct Dashboard {
pub mut:
	rpm u32
	tailgate u32
}

pub fn (mut fb Dashboard) on_100ms(inp ports.DashboardIn, mut out ports.DashboardOut) {
	fb.rpm = inp.engine_rpm.rpm
	fb.tailgate = inp.tailgate_status.open
	out.headlight_cmd.mode = if fb.rpm > 1000 { u32(2) } else { u32(1) }
	out.hvac_cmd.temp = u32(22)
}
