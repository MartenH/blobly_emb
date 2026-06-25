module main

// Platform entry. The only hand-written platform code: open the CAN channel,
// then hand off to gen.run — the generated COM bus bridge + app partitions.
// Bridge, codec, channels, partition entries and signal types are all generated
// from ecu.toml (+ bus.dbc). (Opening the socket is init-time I/O, hence the
// `string` ifname lives here and not in the no-alloc `gen` module.)

import os
import driver.can
import gen

fn main() {
	ifname := if os.args.len > 1 { os.args[1] } else { 'vcan0' }
	println('overspeed: can0@c0 (COM bridge) | sense@c0 | ctrl@c1')
	println('  VehicleSpeed -> SpeedFilter ->(local) OverspeedDetector ->(cross-core) LampController')
	println('  EngineSpeed  -> EngineMonitor ->(local) LampController -> WarnLamp -> bus')

	mut ch := can.Channel{}
	if !ch.open(ifname, gen.can0_fd) {
		eprintln('failed to open "${ifname}" — is vcan up? (make vcan)')
		return
	}
	gen.run(ch)
}
