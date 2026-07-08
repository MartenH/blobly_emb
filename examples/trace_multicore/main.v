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
// Drive it from blobly_net (gen/trace-manifest.csv carries the frame ids + both cores' handlers;
// blobly_net decodes the fixed protocol natively) — a TraceCmd `dump` with core mask 0x0003
// streams one self-describing block per core out over ISO-TP on 0x7E5.
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
