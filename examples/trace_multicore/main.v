module main

// P4 dev harness (host / vcan): multi-core dump-in-one-command + the thread-switch
// swimlane. Two "cores" (each a loom.Scheduler with its own ring TraceBuffer) run on one
// bus loop. A single `dump` with several core_mask bits streams one self-describing
// ISO-TP block per selected core (block-header record + records), so:
//
//   sudo make vcan
//   v -gc none -path "@vlib|@vmodules|." -o /tmp/trace_multicore examples/trace_multicore/main.v
//   /tmp/trace_multicore vcan0 &
//   candump vcan0,7E3:7FF &                 # TraceRsp (one per selected core)
//   isotprecv -s 0x7E6 -d 0x7E5 vcan0 &     # reassemble a block (per core)
//   cansend vcan0 7E2#06000000FFFF0300      # opcode 6 dump, core_mask=0x0003 (cores 0+1)
//
// The host has no preemption, so real thread-switch records only exist on ThreadX; this
// harness INJECTS synthetic switches (app<->isr per core) to exercise the swimlane codec
// and dump end-to-end — the same seam-only stand-in as the DWT `hw` trigger.

import os
import osal
import loom
import comm.trace
import comm.isotp
import driver.can

const cmd_id = u32(0x7E2)
const rsp_id = u32(0x7E3)
const record_id = u32(0x7E5) // ISO-TP data: target -> host
const dump_fc_id = u32(0x7E6) // ISO-TP flow control: host -> target
const ncores = 2
const buf_records = 32 // per core; header + 32*8 = 264 B <= dump_cap
const dump_cap = 512 // one core's block; must be <= isotp.max_payload
const trigger_us = u64(500)
const switch_every = u32(200) // inject a synthetic thread switch every N loop passes

// Fb burns a controlled amount of work so handler timings are distinct and stable.
struct Fb {
mut:
	acc   u32 = 1
	iters u32
	n     u32
}

fn (mut f Fb) step(mul u32) {
	mut a := f.acc
	for _ in 0 .. f.iters * mul {
		a = a * 1664525 + 1013904223
	}
	f.acc = a
}

// Core is one simulated core: its scheduler, its ring buffer, the capture-start baseline,
// and the two work FBs. id_base maps a scheduler index to the global handler_id; thread
// ids for this core are id_base (the app thread) and id_base+1 (a notional preempting ISR).
struct Core {
mut:
	id_base u8
	sched   loom.Scheduler
	buf     trace.TraceBuffer
	start   u64
	light   Fb
	heavy   Fb
	sw_out  bool // synthetic swimlane phase: false = app running, true = app preempted
}

fn (c Core) app_thread() u8 {
	return c.id_base
}

fn (c Core) isr_thread() u8 {
	return c.id_base + 1
}

// capture_hook feeds one handler-run Record per dispatch into this core's ring and fires
// the software trigger when a handler runs over budget.
fn capture_hook(ctx voidptr, idx int, start_us u64, dt_us u64) {
	mut c := unsafe { &Core(ctx) }
	mut dt := dt_us
	if dt > 0xFFFF {
		dt = 0xFFFF
	}
	c.buf.push(trace.Record{
		start_us:   u32(start_us - c.start)
		cpu_us:     u16(dt)
		handler_id: c.id_base + u8(idx) // global id = core base + scheduler index
	})
	if dt_us > trigger_us {
		c.buf.trigger()
	}
}

fn h_light(ctx voidptr) {
	mut c := unsafe { &Core(ctx) }
	c.light.step(1)
}

fn h_heavy(ctx voidptr) {
	mut c := unsafe { &Core(ctx) }
	c.heavy.n++
	c.heavy.step(if c.heavy.n % 40 == 0 { u32(5) } else { u32(1) })
}

fn main() {
	ifname := if os.args.len > 1 { os.args[1] } else { 'vcan0' }
	mut ch := can.Channel{}
	if !ch.open(ifname, false) {
		eprintln('trace_multicore: open "${ifname}" failed — is vcan up? (sudo make vcan)')
		return
	}

	// two cores, each with its own ring buffer backing (no alloc: fixed arrays here).
	mut backing0 := [buf_records]trace.Record{}
	mut backing1 := [buf_records]trace.Record{}
	mut cores := [ncores]Core{}
	cores[0] = Core{
		id_base: 0
		buf:     trace.new_buffer(&backing0[0], u32(buf_records), .ring, 50)
		light:   Fb{
			iters: 3_000
		}
		heavy: Fb{
			iters: 90_000
		}
	}
	cores[1] = Core{
		id_base: 2
		buf:     trace.new_buffer(&backing1[0], u32(buf_records), .ring, 50)
		light:   Fb{
			iters: 5_000
		}
		heavy: Fb{
			iters: 120_000
		}
	}
	now0 := osal.now_us()
	for i in 0 .. ncores {
		cores[i].sched.every(5_000, h_light, &cores[i])
		cores[i].sched.every(20_000, h_heavy, &cores[i])
		cores[i].start = now0
		cores[i].buf.start()
		cores[i].sched.set_trace_hook(capture_hook, &cores[i])
	}
	println('trace_multicore: ${ncores} cores on ${ifname}; dump with core_mask (cmd 0x${cmd_id.hex()}), reassemble per-core blocks on 0x${record_id.hex()}')

	// one shared ISO-TP link + dump buffer: blocks stream one core at a time (serialised on
	// record_id), the block header names the core. `pending` queues cores awaiting dump.
	mut link := isotp.Link{}
	mut dumpbuf := [dump_cap]u8{}
	mut pending := [ncores]bool{}
	mut pass := u32(0)

	for {
		for i in 0 .. ncores {
			cores[i].sched.run_profiled(osal.now_us)
		}

		// synthetic swimlane: periodically inject a thread switch on each core so the dump
		// carries a context-switch timeline (real switches come from ThreadX on target).
		pass++
		if pass % switch_every == 0 {
			for i in 0 .. ncores {
				now := u32(osal.now_us() - cores[i].start)
				if cores[i].sw_out {
					cores[i].buf.push(trace.new_switch(now, cores[i].isr_thread(),
						cores[i].app_thread(), trace.switch_resume))
				} else {
					cores[i].buf.push(trace.new_switch(now, cores[i].app_thread(),
						cores[i].isr_thread(), trace.switch_preempt))
				}
				cores[i].sw_out = !cores[i].sw_out
			}
		}

		mut rx := can.Frame{}
		if ch.recv(mut rx) {
			if rx.id == cmd_id && rx.len >= 8 {
				mut cb := [8]u8{}
				for j in 0 .. 8 {
					cb[j] = rx.data[j]
				}
				c := trace.decode_cmd(cb)
				// fan out: apply the command to every core its mask selects, one rsp each.
				for i in 0 .. ncores {
					if !c.targets(u8(i)) {
						continue
					}
					mut rspb, do_dump := trace.handle_cmd(mut cores[i].buf, c, u8(i))
					if c.opcode == trace.op_arm || c.opcode == trace.op_start
						|| c.opcode == trace.op_reset {
						cores[i].start = osal.now_us()
					}
					if do_dump {
						pending[i] = true // queue this core's block; streamed when the link is free
					}
					mut rf := can.Frame{
						id:  rsp_id
						len: 8
					}
					for j in 0 .. 8 {
						rf.data[j] = rspb[j]
					}
					ch.send(rf)
				}
				// a (re)arm anywhere aborts an in-flight dump so the shared link never wedges.
				if c.opcode == trace.op_arm || c.opcode == trace.op_start
					|| c.opcode == trace.op_reset {
					link = isotp.Link{}
					for i in 0 .. ncores {
						pending[i] = false
					}
				}
			} else if rx.id == dump_fc_id {
				mut p := isotp.Pdu{}
				for j in 0 .. 8 {
					p.data[j] = rx.data[j]
				}
				link.on_frame(osal.now_us(), p)
			}
		}

		// start the next queued core's block once the link is idle (serialise on record_id).
		if !link.busy() {
			for i in 0 .. ncores {
				if pending[i] {
					n := cores[i].buf.pack_block(&dumpbuf[0], dump_cap, u8(i))
					if link.send(&dumpbuf[0], n) {
						pending[i] = false
					}
					break
				}
			}
		}

		// drive the ISO-TP tx: drain the next PDU(s) onto record_id.
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

		osal.sleep_us(1_000)
	}
}
