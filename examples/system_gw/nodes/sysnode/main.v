module main

// Host entry for the DISSOLUTION gateway (system_gw sysnode): open both CAN channels
// and hand off to gen.run — the generated route decodes VehSpeedFrame on can0 and
// re-emits VehSpeed_E on can1. Interface names are a platform binding (overridable).

import os
import driver.can
import gen

fn main() {
	if0 := if os.args.len > 1 { os.args[1] } else { 'vcan0' }
	if1 := if os.args.len > 2 { os.args[2] } else { 'vcan1' }
	println('system_gw gateway: ${if0} (compute) -> route VehicleSpeed -> ${if1} (edge)')
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
