module main

// Platform entry for the CROSS-CORE translating gateway: open both CAN channels and hand
// off to gen.run — the generated bridges run on different cores, and the routed value
// crosses via the IOC channel cfg2v allocated (never a shared CAN channel). Interface
// names are the platform binding, overridable at the CLI: `bin/app vcan0 vcan1`.

import os
import driver.can
import gen

fn main() {
	if0 := if os.args.len > 1 { os.args[1] } else { 'vcan0' }
	if1 := if os.args.len > 2 { os.args[2] } else { 'vcan1' }
	println('gw_xcore: ${if0}@core0 (in: SrcFrame 0x100) -> Speed over IOC -> ${if1}@core1 (out: DstFrame 0x200)')

	mut c0 := can.Channel{}
	if !c0.open(if0, gen.can0_fd) {
		eprintln('failed to open ${if0} — is vcan up? (make vcan)')
		return
	}
	mut c1 := can.Channel{}
	if !c1.open(if1, gen.can1_fd) {
		eprintln('failed to open ${if1} — is vcan up? (make vcan)')
		return
	}
	gen.run(c0, c1)
}
