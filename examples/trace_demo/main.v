module main

// P1 handler-tracing dev harness (host / vcan). Runs three handlers on a loom
// Scheduler with per-handler timing (run_profiled) and pushes one HandlerStat frame per
// handler every second on 0x7E4, so:
//
//   sudo make vcan
//   v -gc none -path "@vlib|@vmodules|." -o /tmp/trace_demo examples/trace_demo/main.v
//   /tmp/trace_demo vcan0 &
//   candump vcan0,7E4:7FF        # b0 = handler_id, b2-3 last_us, b4-5 max_us, b6-7 count
//
// Hand-wired pending the loom2v HandlerStat emitter (the config-driven P1 codegen); it
// exists to develop and verify the loom.run_profiled + telem.encode_handlerstat path on
// WSL before it is generated. The FBs are pure compute so their timings are distinct and
// stable (fast < med < slow).

import os
import osal
import loom
import comm.telem
import comm.trace
import driver.can

const trace_id = u32(0x7E4) // HandlerStat live stats
const record_id = u32(0x7E5) // captured-trace record dump

// Capture holds the one-shot record buffer + the capture start time; passed to the loom
// trace hook as ctx so the hook builds one Record per handler invocation.
struct Capture {
mut:
	buf   trace.TraceBuffer
	start u64
}

fn capture_hook(ctx voidptr, idx int, start_us u64, dt_us u64) {
	mut c := unsafe { &Capture(ctx) }
	mut dt := dt_us
	if dt > 0xFFFF {
		dt = 0xFFFF
	}
	c.buf.push(trace.Record{
		handler_id: u8(idx) // single partition: global id == scheduler index
		start_us:   u32(start_us - c.start)
		cpu_us:     u16(dt)
	})
}

struct Fb {
mut:
	acc   u32 = 1
	iters u32
}

// step burns `iters` LCG rounds — a controllable, observed amount of work (acc is kept
// in the escaping App, so it isn't optimised away).
fn (mut f Fb) step() {
	mut a := f.acc
	for _ in 0 .. f.iters {
		a = a * 1664525 + 1013904223
	}
	f.acc = a
}

struct App {
mut:
	fast Fb
	med  Fb
	slow Fb
}

fn h_fast(ctx voidptr) {
	mut a := unsafe { &App(ctx) }
	a.fast.step()
}

fn h_med(ctx voidptr) {
	mut a := unsafe { &App(ctx) }
	a.med.step()
}

fn h_slow(ctx voidptr) {
	mut a := unsafe { &App(ctx) }
	a.slow.step()
}

fn main() {
	ifname := if os.args.len > 1 { os.args[1] } else { 'vcan0' }
	mut ch := can.Channel{}
	if !ch.open(ifname, false) {
		eprintln('trace_demo: open "${ifname}" failed — is vcan up? (sudo make vcan)')
		return
	}
	println('trace_demo: handlers fast(5ms)/med(10ms)/slow(20ms) -> HandlerStat 0x${trace_id.hex()} @1Hz on ${ifname}')

	mut app := App{
		fast: Fb{
			iters: 3_000
		}
		med:  Fb{
			iters: 30_000
		}
		slow: Fb{
			iters: 120_000
		}
	}
	mut sched := loom.Scheduler{}
	sched.every(5_000, h_fast, &app) // 5 ms
	sched.every(10_000, h_med, &app) // 10 ms
	sched.every(20_000, h_slow, &app) // 20 ms

	// one-shot capture: record every invocation into a 64-record buffer; when it fills,
	// dump the records (0x7E5, one encode_record frame each) and re-arm.
	mut backing := [64]trace.Record{}
	mut cap := Capture{
		buf: trace.new_buffer(&backing[0], 64, .oneshot, 0)
	}
	cap.start = osal.now_us()
	cap.buf.start()
	sched.set_trace_hook(capture_hook, &cap)
	println('trace_demo: capturing 64 records -> dump on 0x${record_id.hex()} when full')

	mut last_push := u64(0)
	mut last_count := [3]u32{}
	for {
		sched.run_profiled(osal.now_us)
		if cap.buf.state() == .full { // one-shot filled -> dump + re-arm
			for i in u32(0) .. cap.buf.used() {
				b := trace.encode_record(cap.buf.record_at(i))
				mut rf := can.Frame{
					id:  record_id
					len: 8
				}
				for j in 0 .. 8 {
					rf.data[j] = b[j]
				}
				ch.send(rf)
			}
			cap.start = osal.now_us()
			cap.buf.start()
		}
		now := osal.now_us()
		if now - last_push >= 1_000_000 { // push HandlerStat once a second
			last_push = now
			for i in 0 .. sched.handler_count() {
				st := sched.handler_stat(i)
				delta := st.count - last_count[i]
				last_count[i] = st.count
				payload := telem.encode_handlerstat(u8(i), 0, st.last_us, st.max_us, delta)
				mut f := can.Frame{
					id:  trace_id
					len: 8
				}
				for j in 0 .. 8 {
					f.data[j] = payload[j]
				}
				ch.send(f)
				sched.reset_handler_max(i) // max is peak-since-last-report
			}
		}
		osal.sleep_us(1_000)
	}
}
