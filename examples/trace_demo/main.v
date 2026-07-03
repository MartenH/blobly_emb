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
import comm.isotp
import driver.can

const trace_id = u32(0x7E4) // HandlerStat live stats
const record_id = u32(0x7E5) // captured-trace record dump (ISO-TP data: target -> host)
const cmd_id = u32(0x7E2) // TraceCmd  (host -> target)
const rsp_id = u32(0x7E3) // TraceRsp  (target -> host)
const dump_fc_id = u32(0x7E6) // ISO-TP flow control for the dump (host -> target)
const trigger_us = u64(500) // freeze the ring when a handler runs longer than this

// Capture holds the ring record buffer + the capture start time; passed to the loom trace
// hook as ctx so the hook builds one Record per handler invocation and applies the
// software trigger (an over-budget handler -> freeze the ring around it).
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
	// software trigger: a handler exceeding its budget freezes the ring with the pre/post
	// window around it — the flight recorder catches the moment of the anomaly.
	if dt_us > trigger_us {
		c.buf.trigger()
	}
}

struct Fb {
mut:
	acc   u32 = 1
	iters u32
	n     u32 // invocation counter (for the periodic glitch)
}

// step burns `mul * iters` LCG rounds — a controllable, observed amount of work (acc is
// kept in the escaping App, so it isn't optimised away).
fn (mut f Fb) step(mul u32) {
	mut a := f.acc
	for _ in 0 .. f.iters * mul {
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
	a.fast.step(1)
}

fn h_med(ctx voidptr) {
	mut a := unsafe { &App(ctx) }
	a.med.step(1)
}

fn h_slow(ctx voidptr) {
	mut a := unsafe { &App(ctx) }
	a.slow.n++
	// every 40th run is a glitch: ~5x the work -> over the trigger budget, firing the
	// ring freeze so the dump shows the window around the anomaly.
	a.slow.step(if a.slow.n % 40 == 0 { u32(5) } else { u32(1) })
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

	// ring capture (flight recorder): record every invocation continuously, overwriting
	// oldest; a handler over its budget (the periodic h_slow glitch) fires the software
	// trigger, freezing with 50% of the ring from before the glitch + 50% after. The host
	// polls status (-> frozen) and dumps the window as one ISO-TP block on 0x7E5.
	mut backing := [64]trace.Record{}
	mut cap := Capture{
		buf: trace.new_buffer(&backing[0], 64, .ring, 50)
	}
	cap.start = osal.now_us()
	cap.buf.start()
	sched.set_trace_hook(capture_hook, &cap)
	mut link := isotp.Link{} // ISO-TP tx for the bulk dump (records on 0x7E5, FC on 0x7E6)
	mut dumpbuf := [512]u8{} // up to 64 records x 8 = the ISO-TP payload
	println('trace_demo: ring capture; trigger on a >${trigger_us}us handler -> freeze; `dump` streams the window (ISO-TP 0x${record_id.hex()})')

	mut last_push := u64(0)
	mut last_count := [3]u32{}
	for {
		sched.run_profiled(osal.now_us)

		// handle an incoming frame: a TraceCmd (control) or an ISO-TP flow-control PDU
		// for an in-flight dump.
		mut rx := can.Frame{}
		if ch.recv(mut rx) {
			if rx.id == cmd_id && rx.len >= 8 {
				mut cb := [8]u8{}
				for j in 0 .. 8 {
					cb[j] = rx.data[j]
				}
				c := trace.decode_cmd(cb)
				mut rspb, do_dump := trace.handle_cmd(mut cap.buf, c, 0)
				if c.opcode == trace.op_arm || c.opcode == trace.op_start || c.opcode == trace.op_reset {
					cap.start = osal.now_us() // relative start_us baseline for the new capture
				}
				if do_dump { // pack the records and start the ISO-TP transfer, if the link is free
					n := cap.buf.pack(&dumpbuf[0], 512)
					if !link.send(&dumpbuf[0], n) {
						rspb[1] = trace.result_busy // a previous dump is still in flight; ack busy, not OK
					}
				}
				mut rf := can.Frame{
					id:  rsp_id
					len: 8
				}
				for j in 0 .. 8 {
					rf.data[j] = rspb[j]
				}
				ch.send(rf)
			} else if rx.id == dump_fc_id { // ISO-TP flow control from the host
				mut p := isotp.Pdu{}
				for j in 0 .. 8 {
					p.data[j] = rx.data[j]
				}
				link.on_frame(osal.now_us(), p)
			}
		}

		// drive the ISO-TP dump tx: drain the next PDU(s) to send on record_id
		mut tp := isotp.Pdu{}
		for link.poll(osal.now_us(), mut tp) {
			mut pf := can.Frame{
				id:  record_id
				len: 8
			}
			for j in 0 .. 8 {
				pf.data[j] = tp.data[j]
			}
			ch.send(pf)
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
