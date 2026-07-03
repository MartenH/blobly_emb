module main

// P4 dev harness (host / vcan): multi-core dump-in-one-command + the thread-switch
// swimlane, with the cross-core boundary modelled by real IOC channels.
//
// Two "cores" (each a loom.Scheduler with its OWN ring TraceBuffer) plus a bus core, all in
// one host process — the host-Linux equivalent of the target's shared SRAM (osal keeps the
// IOC region in a static block until an AMP build swaps it to mmap). Each core touches ONLY
// its own buffer; the bus core reaches a core solely through osal.ioc_* — it never reads or
// writes a remote TraceBuffer (the cross-core SPSC/isolation invariant). A single dump
// command with several core_mask bits streams one self-describing ISO-TP block per core:
//
//   sudo make vcan
//   make run &
//   candump vcan0,7E3:7FF &                 # TraceRsp (one per selected core; b7 = core)
//   isotprecv -s 0x7E6 -d 0x7E5 vcan0 &      # reassemble a block (per core)
//   cansend vcan0 7E2#03000000FFFF0300       # stop cores 0+1 (freeze the rings)
//   cansend vcan0 7E2#06000000FFFF0300       # dump cores 0+1 -> two ISO-TP blocks on 0x7E5
//
// The bus core pulls each core's frozen buffer over IOC in 64-byte chunks (IOC_MAX), the
// same read-out the AMP target does; here the cores are cooperative loops, but the control
// and transport paths are the real ones. Synthetic app<->isr switches are injected per core
// to exercise the swimlane codec (real switches are the ThreadX state-change hook).

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
const buf_records = 32 // per core ring depth
const dump_cap = 512 // one core's packed block / ISO-TP payload (<= isotp.max_payload)
const chunk_data = 56 // dump bytes per IOC chunk (7 records; chunk struct <= IOC_MAX 64)
const trigger_us = u64(500)
const switch_every = u32(30) // inject a synthetic thread switch every N core steps

// IOC channel indices, 4 per core: cmd (bus->core), rsp (core->bus), dump chunk (core->bus),
// ack (bus->core). Distinct indices per core, so no channel is shared by two writers.
fn ch_cmd(c int) int {
	return c * 4 + 0
}

fn ch_rsp(c int) int {
	return c * 4 + 1
}

fn ch_dump(c int) int {
	return c * 4 + 2
}

fn ch_ack(c int) int {
	return c * 4 + 3
}

// IOC message payloads (all <= IOC_MAX = 64 bytes). seq/gen sequence numbers let the reader
// tell a fresh message from a re-read of the last-is-best mailbox.
struct CmdMsg {
mut:
	seq  u8
	data [8]u8
}

struct RspMsg {
mut:
	seq  u8
	gen  u8 // the dump generation this core will stream (so the bus rejects stale chunks)
	data [8]u8
}

struct DumpChunk {
mut:
	gen  u8
	seq  u8
	more u8
	len  u8
	data [chunk_data]u8
}

struct DumpAck {
mut:
	gen u8
	seq u8
}

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

// Core is one simulated core: its scheduler + ring buffer (single-writer: only this core),
// the capture baseline, work FBs, and the producer state for streaming its frozen buffer to
// the bus core over IOC.
struct Core {
mut:
	id_base u8
	sched   loom.Scheduler
	buf     trace.TraceBuffer
	start   u64
	light   Fb
	heavy   Fb
	sw_out  bool // synthetic swimlane phase
	sw_pass u32
	// control handshake
	last_cmd_seq u8
	// dump producer (stream own buffer to the bus in stop-and-wait chunks)
	dumping    bool
	gen        u8
	stage      [dump_cap]u8
	total      int
	off        int
	sent_seq   u8
	acked_seq  u8
	seq_primed bool
}

fn (c Core) app_thread() u8 {
	return c.id_base
}

fn (c Core) isr_thread() u8 {
	return c.id_base + 1
}

fn capture_hook(ctx voidptr, idx int, start_us u64, dt_us u64) {
	mut c := unsafe { &Core(ctx) }
	mut dt := dt_us
	if dt > 0xFFFF {
		dt = 0xFFFF
	}
	c.buf.push(trace.Record{
		start_us:   u32(start_us - c.start)
		cpu_us:     u16(dt)
		handler_id: c.id_base + u8(idx)
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

// core_step runs one core: its scheduler + capture, a synthetic swimlane switch, its command
// handshake (applied to its OWN buffer), and one step of streaming its frozen buffer out.
fn core_step(mut c Core, i int) {
	c.sched.run_profiled(osal.now_us)

	// synthetic swimlane: inject an app<->isr switch into this core's own buffer.
	c.sw_pass++
	if c.sw_pass % switch_every == 0 {
		now := u32(osal.now_us() - c.start)
		if c.sw_out {
			c.buf.push(trace.new_switch(now, c.isr_thread(), c.app_thread(), trace.switch_resume))
		} else {
			c.buf.push(trace.new_switch(now, c.app_thread(), c.isr_thread(), trace.switch_preempt))
		}
		c.sw_out = !c.sw_out
	}

	// command from the bus core (only this core touches its buffer).
	mut cm := CmdMsg{}
	if osal.ioc_read(ch_cmd(i), &cm, u8(sizeof(cm))) && cm.seq != c.last_cmd_seq {
		c.last_cmd_seq = cm.seq
		cmd := trace.decode_cmd(cm.data)
		mut rspb, do_dump, _ := trace.handle_cmd(mut c.buf, cmd, u8(i)) // bus pre-filters by core_mask
		if cmd.opcode == trace.op_arm || cmd.opcode == trace.op_start
			|| cmd.opcode == trace.op_reset {
			c.start = osal.now_us()
			c.dumping = false
		}
		if do_dump && !c.dumping {
			// Only a multi-core dump needs the per-core block header (to split the shared
			// record_id stream). A single-core dump is raw records — the TraceRsp names the
			// core — matching the wire contract, so single-core tooling isn't misled.
			c.total = if multi_core(cmd) {
				c.buf.pack_block(&c.stage[0], dump_cap, u8(i))
			} else {
				c.buf.pack(&c.stage[0], dump_cap)
			}
			c.gen++
			c.off = 0
			c.sent_seq = 0
			c.acked_seq = 0
			c.seq_primed = false
			// always stream, even for an empty single-core dump (total 0 -> one terminal
			// len-0 chunk), so the bus gets a completion signal instead of waiting forever.
			c.dumping = true
		}
		mut rm := RspMsg{
			seq: cm.seq
			gen: c.gen // the generation of the block this core is about to stream (if any)
		}
		for j in 0 .. 8 {
			rm.data[j] = rspb[j]
		}
		osal.ioc_write(ch_rsp(i), &rm, u8(sizeof(rm)))
	}

	// stream the frozen buffer to the bus core, one acked chunk at a time.
	if c.dumping {
		mut ak := DumpAck{}
		if osal.ioc_read(ch_ack(i), &ak, u8(sizeof(ak))) && ak.gen == c.gen && ak.seq > c.acked_seq {
			c.acked_seq = ak.seq
		}
		if c.acked_seq == c.sent_seq { // last chunk acked (or none sent yet): advance
			if c.off >= c.total && c.seq_primed {
				c.dumping = false // whole block sent and acked
			} else {
				mut chk := DumpChunk{
					gen: c.gen
					seq: c.sent_seq + 1
				}
				mut n := c.total - c.off
				if n > chunk_data {
					n = chunk_data
				}
				for j in 0 .. n {
					chk.data[j] = c.stage[c.off + j]
				}
				chk.len = u8(n)
				c.off += n
				chk.more = if c.off < c.total { u8(1) } else { u8(0) }
				c.sent_seq++
				c.seq_primed = true
				osal.ioc_write(ch_dump(i), &chk, u8(sizeof(chk)))
			}
		}
	}
}

// Bus holds the read-out state on the bus core: which cores still owe a block for the
// current dump command, the single in-flight block being assembled from IOC chunks, and the
// ISO-TP link that carries a completed block to the host.
struct Bus {
mut:
	cmd_seq      [ncores]u8 // per-core: a single global counter could wrap to a core's last
	last_rsp_seq [ncores]u8
	rsp_primed   [ncores]bool
	awaiting     [ncores]bool // dump forwarded, TraceRsp not yet seen
	ready        [ncores]bool // core replied OK to a dump: a block is coming, not yet assembled
	ready_gen    [ncores]u8   // the generation that core will stream (from its OK reply)
	assembling   bool
	active       int = -1
	recv_seq     u8
	recv_gen     u8
	asm          [dump_cap]u8
	asm_len      int
	tx_core      int = -1 // core whose block the ISO-TP link is currently transmitting (-1 = none)
}

fn (b Bus) dump_in_flight(link isotp.Link) bool {
	if b.assembling || link.busy() {
		return true
	}
	for c in 0 .. ncores {
		if b.awaiting[c] || b.ready[c] {
			return true
		}
	}
	return false
}

fn main() {
	ifname := if os.args.len > 1 { os.args[1] } else { 'vcan0' }
	mut ch := can.Channel{}
	if !ch.open(ifname, false) {
		eprintln('trace_multicore: open "${ifname}" failed — is vcan up? (sudo make vcan)')
		return
	}

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
	println('trace_multicore: ${ncores} cores on ${ifname}; dump with core_mask (cmd 0x${cmd_id.hex()}); per-core blocks reassembled from IOC, streamed on 0x${record_id.hex()}')

	mut bus := Bus{}
	mut link := isotp.Link{}

	for {
		// each core runs first and owns its buffer entirely.
		for i in 0 .. ncores {
			core_step(mut cores[i], i)
		}

		// bus core: CAN in, forward commands over IOC, collect rsps + dump chunks over IOC.
		mut rx := can.Frame{}
		if ch.recv(mut rx) {
			if rx.id == cmd_id && rx.len >= 8 {
				mut cb := [8]u8{}
				for j in 0 .. 8 {
					cb[j] = rx.data[j]
				}
				c := trace.decode_cmd(cb)
				if c.opcode == trace.op_dump && bus.dump_in_flight(link) {
					// serialise dumps: reject a new dump while one is still in flight, so
					// blocks from two commands can't interleave on 0x7E5.
					for i in 0 .. ncores {
						if c.targets(u8(i)) {
							ch.send(busy_rsp(u8(i)))
						}
					}
				} else {
					for i in 0 .. ncores {
						if !c.targets(u8(i)) {
							continue
						}
						bus.cmd_seq[i]++ // per core, so it always differs from that core's last
						mut m := CmdMsg{
							seq: bus.cmd_seq[i]
						}
						m.data = cb
						osal.ioc_write(ch_cmd(i), &m, u8(sizeof(m)))
						if c.opcode == trace.op_dump {
							bus.awaiting[i] = true // awaiting the rsp; ready only on an OK reply
						}
					}
					if c.opcode == trace.op_arm || c.opcode == trace.op_start
						|| c.opcode == trace.op_reset {
						// re-arm aborts a dump only for the cores it targets (each also gets the
						// reset over IOC, clearing its own producer); a non-targeted core mid-dump
						// keeps streaming, so its state stays in sync with the bus.
						for i in 0 .. ncores {
							if !c.targets(u8(i)) {
								continue
							}
							bus.awaiting[i] = false
							bus.ready[i] = false
							if bus.active == i { // this core's block was mid-assembly -> drop it
								link = isotp.Link{}
								bus.assembling = false
								bus.active = -1
							}
							if bus.tx_core == i { // this core's block was mid ISO-TP -> abort it
								link = isotp.Link{}
								bus.tx_core = -1
							}
						}
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

		// forward each core's TraceRsp to the host; a not-ready dump means no block coming.
		for i in 0 .. ncores {
			mut rm := RspMsg{}
			if osal.ioc_read(ch_rsp(i), &rm, u8(sizeof(rm))) && (!bus.rsp_primed[i]
				|| rm.seq != bus.last_rsp_seq[i]) {
				bus.rsp_primed[i] = true
				bus.last_rsp_seq[i] = rm.seq
				mut rf := can.Frame{
					id:  rsp_id
					len: 8
				}
				for j in 0 .. 8 {
					rf.data[j] = rm.data[j]
				}
				ch.send(rf)
				if rm.data[0] == trace.op_dump {
					// the block is coming only if the core accepted the dump (frozen/full);
					// a not-ready reply means no chunks, so never start assembling that core.
					bus.awaiting[i] = false
					// only honour a dump reply for the latest command sent to this core; a
					// reset (which bumps cmd_seq[i]) supersedes an earlier dump, so its stale
					// OK reply must not re-arm assembly for a core that was reset.
					if rm.data[1] == trace.result_ok && rm.seq == bus.cmd_seq[i] {
						bus.ready[i] = true
						bus.ready_gen[i] = rm.gen // require chunks of this exact generation
					}
				}
			}
		}

		// assemble one core's block from IOC chunks (ascending core order, link idle to
		// start) — only cores that replied OK, so a not-ready core can't wedge assembly.
		if !bus.assembling && !link.busy() {
			for i in 0 .. ncores {
				if bus.ready[i] {
					bus.active = i
					bus.ready[i] = false
					bus.assembling = true
					bus.asm_len = 0
					bus.recv_seq = 0
					bus.recv_gen = bus.ready_gen[i] // fixed up-front so a stale first chunk is rejected
					break
				}
			}
		}
		if bus.assembling {
			mut chk := DumpChunk{}
			if osal.ioc_read(ch_dump(bus.active), &chk, u8(sizeof(chk))) && chunk_expected(bus, chk) {
				for j in 0 .. int(chk.len) {
					bus.asm[bus.asm_len + j] = chk.data[j]
				}
				bus.asm_len += int(chk.len)
				bus.recv_seq = chk.seq
				mut ak := DumpAck{
					gen: chk.gen
					seq: chk.seq
				}
				osal.ioc_write(ch_ack(bus.active), &ak, u8(sizeof(ak)))
				if chk.more == 0 {
					// an empty block (0 bytes) has nothing to transmit — the TraceRsp already
					// reported records_used 0; only ISO-TP a non-empty block.
					if bus.asm_len > 0 {
						link.send(&bus.asm[0], bus.asm_len)
						bus.tx_core = bus.active // track whose block is now on the link
					}
					bus.assembling = false
					bus.active = -1
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
		if bus.tx_core >= 0 && !link.busy() { // the in-flight ISO-TP block finished (or aborted)
			bus.tx_core = -1
		}

		osal.sleep_us(1_000)
	}
}

// multi_core reports whether a command's core_mask selects more than one core (so its dump
// blocks need per-core headers). A zero mask is the single receiving core; otherwise it's
// multi-core iff more than one bit is set.
fn multi_core(c trace.Cmd) bool {
	m := c.core_mask
	return m != 0 && (m & (m - 1)) != 0
}

// chunk_expected reports whether a dump chunk is the next one for the block being assembled.
// recv_gen is fixed from the core's OK reply before any chunk is read, so EVERY chunk — the
// first included — must carry that generation and be in sequence; a stale chunk left in the
// last-is-best mailbox from a prior dump (even one with seq 1) is rejected.
fn chunk_expected(b Bus, chk DumpChunk) bool {
	return chk.gen == b.recv_gen && chk.seq == b.recv_seq + 1
}

// busy_rsp builds a TraceRsp that rejects a dump because one is already in flight.
fn busy_rsp(core u8) can.Frame {
	rspb := trace.encode_rsp(trace.Rsp{
		opcode_echo: trace.op_dump
		result:      trace.result_busy
		core:        core
	})
	mut rf := can.Frame{
		id:  rsp_id
		len: 8
	}
	for j in 0 .. 8 {
		rf.data[j] = rspb[j]
	}
	return rf
}
