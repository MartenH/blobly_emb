module main

// Platform entry for a two-channel ECU: open both CAN channels and hand off to
// gen.run — the generated per-bus COM bridges + the app partition. The interface
// names are a platform binding, so they live here (the no-heap exempt entry), not
// in generated config. Override at the CLI: `bin/app vcan0 vcan1`.
//
// gen.run's signature has one channel per bus, sorted by name (can0, can1).

import os
import driver.can
import gen

fn main() {
	if0 := if os.args.len > 1 { os.args[1] } else { 'vcan0' }
	if1 := if os.args.len > 2 { os.args[2] } else { 'vcan1' }
	println('gateway: ${if0} (in: VehicleSpeed) | mon@c1 SpeedMonitor | ${if1} (out: WarnLamp)')

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
