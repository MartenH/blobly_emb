module main

// Platform entry: open the CAN channel, then hand off to gen.run — the
// generated COM bus bridge + app partition. Everything else is generated from
// ecu.toml (+ bus.dbc).

import os
import driver.can
import gen

fn main() {
	ifname := if os.args.len > 1 { os.args[1] } else { 'vcan0' }
	println('minimal: can0@c0 (COM bridge) | app@c1 SpeedMonitor (lamp when >120 km/h)')

	mut ch := can.Channel{}
	if !ch.open(ifname, gen.can0_fd) {
		eprintln('failed to open "${ifname}" — is vcan up? (make vcan)')
		return
	}
	gen.run(ch)
}
