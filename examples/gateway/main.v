module main

// Platform entry for a two-channel ECU: open both CAN channels (by their config
// interfaces) and hand off to gen.run — the generated per-bus COM bridges + the
// app partition. gen.run's signature has one channel per bus, sorted by name.

import driver.can
import gen

fn main() {
	println('gateway: can0 (in: VehicleSpeed) | mon@c1 SpeedMonitor | can1 (out: WarnLamp)')

	mut c0 := can.Channel{}
	if !c0.open(gen.can0_iface, gen.can0_fd) {
		eprintln('failed to open ${gen.can0_iface} — is vcan up? (make vcan)')
		return
	}
	mut c1 := can.Channel{}
	if !c1.open(gen.can1_iface, gen.can1_fd) {
		eprintln('failed to open ${gen.can1_iface} — is vcan up? (make vcan)')
		return
	}
	gen.run(c0, c1)
}
