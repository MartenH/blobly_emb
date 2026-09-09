module main

// Comm-thread trace demo (P3b, different-bus) — fully generated from ecu.toml. The only hand-written
// source: open the two channels and hand off to gen.run(). The can0 COM bridge (the comm thread)
// and the app FB are generated into gen/loom_gen.v; can1 gets its own partition as the module
// host. run()'s params are the buses in NAME order.
//
// The BRIDGE-OWNER runner (#191 P3b): the can0 bridge partition owns the trace bus and the
// TraceModule and records its OWN drain spans, so `comm_can0` is a lane in the dump beside the
// app's. fb_hook never fires for a bridge — it dispatches a COM drain, not FB handlers — so its
// lane comes from trace.thread_hook instead, which is what P3b is for.
//
// run()'s shape is unchanged (`run(can0, can1)`): can1 is still a parameter, it is simply handed
// to the bridge rather than to a partition of its own. A dump answers TWO blocks, one per core.
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
