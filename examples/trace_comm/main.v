module main

// Comm-thread trace demo (P3b, different-bus) — fully generated from ecu.toml. The only hand-written
// source: open the two channels and hand off to gen.run(). The can0 COM bridge (the comm thread)
// and the app FB are generated into gen/loom_gen.v; can1 gets its own partition as the module
// host. run()'s params are the buses in NAME order.
//
// REGRESSED: the trace ring + dump on can1. P3b shipped in #60; a later refactor left loom2v
// generating trace for the single-partition host shape only, and it WARNS when it drops the rest.
// The comm/app halves build and run; the swimlane this example is named for needs that generator
// wiring back. See #191.
//
//   sudo make vcan      # brings up vcan0 (app) + vcan1 (trace)
//   make run
//
// Feed VehicleSpeed on vcan0 and dump on vcan1: the swimlane shows a `comm_can0` lane (the bridge's
// per-drain-cycle work) beside the app's SpeedWork lane.
import os
import gen
import driver.can

fn main() {
	trace_if := if os.args.len > 1 { os.args[1] } else { 'vcan1' } // dedicated trace bus
	app_if := if os.args.len > 2 { os.args[2] } else { 'vcan0' } // app signal bus (comm bridge)
	mut trch := can.Channel{}
	if !trch.open(trace_if, gen.can1_fd) {
		eprintln('trace_comm: open trace bus "${trace_if}" failed — is vcan up? (sudo make vcan)')
		return
	}
	mut appch := can.Channel{}
	if !appch.open(app_if, gen.can0_fd) {
		eprintln('trace_comm: open app bus "${app_if}" failed')
		return
	}
	println('trace_comm: app SpeedWork (core 1) + comm_can0 bridge (core 0); trace on ${trace_if}, VehicleSpeed on ${app_if}')
	// Channels go in BUS-NAME order (can0, can1) — run()'s params are sorted so the signature
	// stays stable as buses are added, not in the order this file happens to open them.
	gen.run(appch, trch)
}
