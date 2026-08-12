module main

// Two-core handler-tracing demo — fully generated from ecu.toml (loom2v P3a). This is the only
// hand-written source: open the trace bus channel and hand off to gen.run(ch). Everything else —
// the two partitions' FBs (app/work.v), the per-core capture rings, the single partition_trace
// owner (TraceCmd/TraceRsp + the per-core ISO-TP dump), and CpuLoad — is generated into
// gen/loom_gen.v from the [trace]/[telemetry]/[[partition]]/[[fb]] blocks. (This replaces the
// earlier hand-wired P4 harness — nothing here is bespoke now; the wiring comes from the config.)
//
//   sudo make vcan          # once, to bring up vcan0
//   make run                # generate + build + run on vcan0
//
// NOT YET, and the reason this example was skipped by CI: loom2v generates the trace ring +
// dump for the SINGLE-partition host shape only, and warns when it drops it on any other. This
// config is two partitions, so it builds and runs the two cores' FBs — but no `dump` answers on
// 0x7E5 and gen/trace-manifest.csv carries no handler rows. comm/trace itself is ready (a module
// carries one local core plus one imported remote, and multicore_dump_test proves two
// self-describing blocks over ISO-TP); it is the generator wiring that is missing. See #191.
import os
import gen
import driver.can

fn main() {
	ifname := if os.args.len > 1 { os.args[1] } else { 'vcan0' }
	mut ch := can.Channel{}
	if !ch.open(ifname, gen.can0_fd) { // the trace bus's fd setting from ecu.toml
		eprintln('trace_multicore: open "${ifname}" failed — is vcan up? (sudo make vcan)')
		return
	}
	println('trace_multicore: core0 sense(5/10ms) + core1 ctrl(10/20ms) on ${ifname}; `dump` (mask 0x0003) streams one ring block per core (ISO-TP 0x7E5)')
	gen.run(ch)
}
