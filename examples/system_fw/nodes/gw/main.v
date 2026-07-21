module main

// Host entry for the DISSOLUTION firewall gateway (system_fw gw): open both CAN
// channels and hand off to gen.run — the generated FRAME route raw-forwards
// DiagFrame from can0 (compute) to can1 (edge), unchanged. Only that frame crosses;
// PrivateFrame on compute never reaches edge. Interface names are a platform binding.

import os
import driver.can
import gen

fn main() {
	if0 := if os.args.len > 1 { os.args[1] } else { 'vcan0' }
	if1 := if os.args.len > 2 { os.args[2] } else { 'vcan1' }
	println('system_fw firewall: ${if0} (compute) -> raw-forward DiagFrame -> ${if1} (edge)')
	mut c0 := can.Channel{}
	if !c0.open(if0, gen.can0_fd) {
		eprintln('failed to open ${if0} — is vcan up?')
		return
	}
	mut c1 := can.Channel{}
	if !c1.open(if1, gen.can1_fd) {
		eprintln('failed to open ${if1} — is vcan up?')
		return
	}
	gen.run(c0, c1)
}
