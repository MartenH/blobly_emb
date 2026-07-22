module main

// Platform entry for the translating gateway: open both CAN channels and hand off
// to gen.run — the generated per-bus COM bridge does the decode → re-encode. The
// interface names are a platform binding (the no-heap exempt entry), overridable at
// the CLI: `bin/app vcan0 vcan1`.

import os
import driver.can
import gen

fn main() {
	if0 := if os.args.len > 1 { os.args[1] } else { 'vcan0' }
	if1 := if os.args.len > 2 { os.args[2] } else { 'vcan1' }
	println('gw_extid: ${if0} -> raw-forward extended-id frame ExtDiag (0x10FD0500) -> ${if1}')

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
