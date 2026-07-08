module main

// Single-core handler-tracing demo — fully generated from ecu.toml. This is the only
// hand-written source: open the trace bus channel and hand off to gen.run(ch). Everything
// else — the three pure-compute FBs (app/work.v), the loom wiring, the trace capture ring +
// TraceCmd/TraceRsp + ISO-TP dump, the HandlerStat heartbeat, and CpuLoad — is generated into
// gen/loom_gen.v from the [trace]/[telemetry]/[[partition]]/[[fb]] blocks.
//
//   sudo make vcan          # once, to bring up vcan0
//   make run                # generate + build + run on vcan0
//   candump vcan0,7E4:7FF   # b0 handler_id, b2-3 last_us, b4-5 max_us, b6-7 count_delta
//
// Drive it from blobly_net (gen/trace-manifest.csv carries the frame ids; blobly_net decodes the
// fixed protocol natively) — TraceCmd `dump` streams the frozen ring out over ISO-TP on 0x7E5.
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
	println('trace_demo: fast(5ms)/med(10ms)/slow(20ms) -> HandlerStat 0x7E4 @1Hz on ${ifname}; `dump` streams the ring (ISO-TP 0x7E5)')
	gen.run(ch)
}
