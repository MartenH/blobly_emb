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
import driver.can

const trace_id = u32(0x7E4)

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

	mut last_push := u64(0)
	mut last_count := [3]u32{}
	for {
		sched.run_profiled(osal.now_us)
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
