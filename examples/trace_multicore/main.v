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
// REGRESSED, which is why CI was skipping this: P3a shipped in #57 and a later refactor took the
// multi-partition trace runner with it. loom2v now generates the ring + dump for the
// single-partition host shape only, and WARNS when it drops the rest — so this builds and runs
// both cores' FBs, and gen/trace-manifest.csv still carries their handler + thread rows, but no
// `dump` is answered on 0x7E5. comm/trace is untouched and still ready (one local core plus one
// imported remote; multicore_dump_test proves two self-describing blocks over ISO-TP) — it is the
// generator wiring that has to come back. See #191.
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
	println('trace_multicore: core0 sense(5/10ms) + core1 ctrl(10/20ms) on ${ifname}; the `dump` this example is named for is NOT generated for this shape yet — see #191')
	gen.run(ch)
}
