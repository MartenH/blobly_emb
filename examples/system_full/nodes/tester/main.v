module main

// Host entry for the system_full TESTER node: open the compute bus and hand off to gen.run.
// On the bench blobly_net stands in for this node; in the sim this binary IS the tester.

import os
import driver.can
import gen

fn main() {
	ifname := if os.args.len > 1 { os.args[1] } else { 'vcan0' }
	println('system_full tester: ${ifname} (compute) — HostBreather -> HostLedLevel (0x127) @ 0.5 Hz')
	mut ch := can.Channel{}
	if !ch.open(ifname, gen.can0_fd) {
		eprintln('failed to open "${ifname}" — is vcan up? (make vcan)')
		return
	}
	gen.run(ch)
}
