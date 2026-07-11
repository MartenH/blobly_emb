module main

// Single-core handler-tracing demo — fully generated from ecu.toml. This is the only
// hand-written source: open the trace bus channel and hand off to gen.run(ch). The trace
// protocol itself is the PLATFORM's TraceModule (comm/trace) — the generated loop only wires
// it: the [trace] endpoint bindings route TraceCmd to on_cmd and stream produce() back out
// (docs/com-modules.md). The FBs, loom wiring, and CpuLoad come from the same ecu.toml.
//
//   sudo make vcan                    # once, to bring up vcan0
//   make run                          # generate + build + run on vcan0
//   cansend vcan0 7E2#01              # arm   -> rsp on 7E3 (or wait for the >500us trigger)
//   cansend vcan0 7E2#03              # stop  (freeze at the current fill)
//   cansend vcan0 7E2#06              # dump  -> the ring streams as raw records on 7E5
//
// gen/trace-manifest.csv carries the frame ids + fb-id names for decoding.
import os
import gen
import driver.can

fn main() {
	ifname := if os.args.len > 1 { os.args[1] } else { 'vcan0' }
	mut ch := can.Channel{}
	if !ch.open(ifname, gen.can0_fd) { // the trace bus's fd setting from ecu.toml
		eprintln('trace_demo: open "${ifname}" failed — is vcan up? (sudo make vcan)')
		return
	}
	println('trace_demo: fast(5ms)/med(10ms)/slow(20ms); TraceCmd 0x7E2 -> rsp 0x7E3; dump streams raw records on 0x7E5 (${ifname})')
	gen.run(ch)
}
