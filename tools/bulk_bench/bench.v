// bulk_bench — the bulk-transport THROUGHPUT harness (ROADMAP: "how big before it
// should leave the chip" as a measured number, not an assumption).
//
// Measures the merged portable bulk ring (boards/common/bulk.h, REQ-BULK-001..003)
// cross-PROCESS — fork + MAP_SHARED, the AMP shape ioc_bench_mp pioneered — and puts
// the numbers next to ISO-TP for the same payload:
//
//   1. ring throughput: payloads/s and MB/s at 64 B .. 4 KB, max-rate producer child;
//   2. ring latency: producer stamps its clock into the payload, a PACED producer
//      (so the pool never saturates) lets the consumer measure publish->take delay;
//   3. ISO-TP, same payload: host CPU cost of the full segmentation round
//      (send -> frame poll -> on_frame -> take) plus the THEORETICAL wire time those
//      frames need on a 500 kbit/s classic bus — the honest off-chip comparison: on
//      the host ISO-TP is only CPU, on a car it is dominated by the bus.
//
//   v -gc none run tools/bulk_bench/bench.v
module main

import comm.isotp
import time

#flag -I @VMODROOT/boards/common
#flag -I @VMODROOT/tools/bulk_bench
#include "bulk.h"
#include "bench_util.h"
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

fn C.bulk_init(b voidptr, nbuf u32, bufsz u32)
fn C.bulk_loan(b voidptr) int
fn C.bulk_buf(b voidptr, idx u32) &u8
fn C.bulk_publish(b voidptr, idx u32, len u32)
fn C.bulk_take(b voidptr, len &u32) int
fn C.bulk_release(b voidptr, idx u32)
fn C.bulk_overflows(b voidptr) u32

fn C.mmap(addr voidptr, len usize, prot int, flags int, fd int, off i64) voidptr
fn C.munmap(addr voidptr, len usize) int
fn C.fork() int
fn C.waitpid(pid int, status &int, options int) int
fn C._exit(code int)
fn C.pin_cpu(cpu int) int
fn C.cpu_ns() i64
fn C.exited_ok(status int) int
fn C.partner_cpu() int

const nbuf = u32(4)
const sizes = [u32(64), 256, 1024, 4096]
const run_ms = i64(1000)
const lat_samples = 2000
const region_bytes = usize(64 * 1024) // > BULK_BYTES(4, 4096)

// classic CAN @ 500 kbit/s: a full 8-byte data frame is ~130 bit times with stuffing
// headroom -> ~260 us per frame. ISO-TP carries 7 payload bytes per CF (6 in the FF).
const us_per_frame = f64(260)

fn region_new() voidptr {
	// PROT_READ|PROT_WRITE = 0x3, MAP_SHARED|MAP_ANONYMOUS = 0x21 (linux) — MAP_SHARED is
	// the bit the whole fork methodology depends on
	r := C.mmap(unsafe { nil }, region_bytes, 0x1 | 0x2, 0x01 | 0x20, -1, 0)
	if r == unsafe { voidptr(-1) } {
		panic('mmap failed')
	}
	return r
}

// ---- 1. ring throughput ----------------------------------------------------------

fn bench_ring_throughput(bufsz u32, fill bool) {
	b := region_new()
	C.bulk_init(b, nbuf, bufsz)
	// the stop flag lives at the region tail: the parent raises it when ITS window
	// ends, so the producer's lifetime is synchronized with the measurement instead
	// of guessed via slack — a delayed rendezvous can no longer leave the window
	// half-empty while the child exits 'ok' (codex #216 r4)
	stop := unsafe { &u32(usize(b) + region_bytes - 4) }
	pid := C.fork()
	if pid < 0 {
		panic('fork failed')
	}
	if pid == 0 {
		// producer child: PINNED to a different PHYSICAL core than the parent's cpu0
		// (partner_cpu skips SMT siblings — logical 0/1 often share L1/L2, which would
		// inflate a 'cross-core' number). Pump at max rate until the parent raises the
		// stop flag; flag checked every 1024 payloads to stay out of the hot path.
		if C.pin_cpu(C.partner_cpu()) != 0 {
			C._exit(9) // parent's exit check reports it — pinning is the measurement's premise
		}
		sw := time.new_stopwatch()
		for {
			for _ in 0 .. 1024 {
				idx := C.bulk_loan(b)
				if idx < 0 {
					continue
				}
				mut p := unsafe { &u8(C.bulk_buf(b, u32(idx))) }
				if fill {
					// FILLED mode: write every byte, so the rate includes the real
					// cache traffic a producing FB pays — the honest bytes/s
					for i in u32(0) .. bufsz {
						unsafe {
							p[i] = u8(i)
						}
					}
				} else {
					// OWNERSHIP mode: first + last byte only — the transport's own
					// cost; the payload is filled in place and never copied by it
					unsafe {
						p[0] = 1
						p[bufsz - 1] = 2
					}
				}
				C.bulk_publish(b, u32(idx), bufsz)
			}
			if unsafe { *stop } != 0 {
				break
			}
			if sw.elapsed().seconds() > 30 {
				C._exit(8) // parent never raised stop — refuse to exit 'ok'
			}
		}
		C._exit(0)
	}
	if C.pin_cpu(0) != 0 {
		panic('cannot pin to cpu0 — run outside the restricted cpuset; unpinned numbers would be mislabeled')
	}
	// rendezvous: the window starts at the FIRST observed payload, so child scheduling
	// delay is not counted as dead time
	mut len := u32(0)
	mut first := C.bulk_take(b, &len)
	first_sw := time.new_stopwatch()
	for first < 0 {
		if first_sw.elapsed().milliseconds() > 5000 {
			panic('producer never published — child dead?')
		}
		first = C.bulk_take(b, &len)
	}
	C.bulk_release(b, u32(first))
	mut got := u64(1)
	mut sink := u64(0)
	sw := time.new_stopwatch()
	for {
		for _ in 0 .. 1024 {
			idx := C.bulk_take(b, &len)
			if idx < 0 {
				continue
			}
			if fill {
				// consume every byte — the reader's half of the real cache traffic
				p := unsafe { &u8(C.bulk_buf(b, u32(idx))) }
				for i in u32(0) .. len {
					unsafe {
						sink += u64(p[i])
					}
				}
			}
			got++
			C.bulk_release(b, u32(idx))
		}
		if sw.elapsed().milliseconds() >= run_ms {
			break
		}
	}
	el_us := f64(sw.elapsed().microseconds())
	unsafe {
		*stop = 1
	}
	// snapshot the saturation counter AT the window boundary: the producer keeps
	// pumping ~300 ms of pure failed loans during shutdown, which would otherwise
	// dominate the printed number (codex #216 r2). One u32 volatile read of a
	// producer-owned counter — a report, not a synchronized value.
	ovf := C.bulk_overflows(b)
	mut status := 0
	C.waitpid(pid, &status, 0)
	if C.exited_ok(status) == 0 {
		panic('producer child died or could not pin (status ${status}) — not a measurement')
	}
	rate := f64(got) * 1000.0 * 1000.0 / el_us / 1000.0 / 1000.0
	if fill {
		mbps := f64(got) * f64(bufsz) / el_us
		// PAYLOAD throughput: one bufsz per transfer. The memory system moves ~2x
		// this (producer writes + consumer reads) — labeled, not silently doubled.
		println('  ${bufsz:5} B filled:    ${rate:6.2f} M transfers/s  ${mbps:7.0f} MB/s payload (memory traffic ~2x; checksum ${sink & 0xff})')
	} else {
		println('  ${bufsz:5} B ownership: ${rate:6.2f} M transfers/s  (transport cost only; ${ovf} failed loans at saturation)')
	}
	C.munmap(b, region_bytes)
}

// ---- 2. ring latency -------------------------------------------------------------

fn bench_ring_latency(bufsz u32) {
	b := region_new()
	C.bulk_init(b, nbuf, bufsz)
	pid := C.fork()
	if pid < 0 {
		panic('fork failed')
	}
	if pid == 0 {
		// PACED producer (one payload per ~200 us), PINNED to core 1: the pool never
		// saturates, so the measured delay is the transport's, not queueing. The stamp
		// is the child's monotonic clock; parent and child share the base on Linux.
		if C.pin_cpu(C.partner_cpu()) != 0 {
			C._exit(9)
		}
		mut sent := 0
		for sent < lat_samples {
			idx := C.bulk_loan(b)
			if idx < 0 {
				continue
			}
			mut p := unsafe { &i64(C.bulk_buf(b, u32(idx))) }
			unsafe {
				*p = time.sys_mono_now()
			}
			C.bulk_publish(b, u32(idx), bufsz)
			sent++
			time.sleep(200 * time.microsecond)
		}
		C._exit(0)
	}
	if C.pin_cpu(0) != 0 {
		panic('cannot pin to cpu0 — run outside the restricted cpuset; unpinned numbers would be mislabeled')
	}
	mut lats := []i64{cap: lat_samples}
	live := time.new_stopwatch()
	for lats.len < lat_samples {
		if live.elapsed().seconds() > 30 {
			panic('latency producer stalled — child dead?') // loud, never a hung make bench
		}
		mut len := u32(0)
		idx := C.bulk_take(b, &len)
		if idx < 0 {
			continue
		}
		stamp := unsafe { *(&i64(C.bulk_buf(b, u32(idx)))) }
		lats << time.sys_mono_now() - stamp
		C.bulk_release(b, u32(idx))
	}
	mut status := 0
	C.waitpid(pid, &status, 0)
	if C.exited_ok(status) == 0 {
		panic('latency producer died (status ${status})')
	}
	lats.sort()
	median := f64(lats[lats.len / 2]) / 1000.0
	p99 := f64(lats[(lats.len - 1) * 99 / 100]) / 1000.0
	println('  median ${median:7.1f} us   p99 ${p99:7.1f} us (publish -> take, paced, distinct physical cores)')
	C.munmap(b, region_bytes)
}

// ---- 3. ISO-TP, same payload -----------------------------------------------------

// One full segmentation round through a back-to-back Link pair on the host: sender
// frames -> receiver on_frame (receiver's FC frames -> sender). Returns CPU us and
// the CAN frame count the transfer needed.
fn isotp_round(mut tx isotp.Link, mut rx isotp.Link, payload []u8, mut dst []u8, mut sink &u64) int {
	mut frames := 0
	if !tx.send(&payload[0], payload.len) {
		panic('isotp send refused (len ${payload.len})')
	}
	mut now := u64(1)
	for {
		mut p := isotp.Pdu{}
		mut moved := false
		if tx.poll(now, mut p) {
			frames++
			rx.on_frame(now, p)
			moved = true
		}
		mut fc := isotp.Pdu{}
		if rx.poll(now, mut fc) {
			frames++
			tx.on_frame(now, fc)
			moved = true
		}
		n := rx.take(unsafe { &dst[0] })
		if n > 0 {
			// consume EVERY reassembled byte: sampling only the ends still lets -prod
			// eliminate the interior stores whose cost this measures; the fold's own
			// cost is fair — a transfer is not done until the consumer reads it
			// (codex #216 r2)
			for i in 0 .. n {
				unsafe {
					*sink += u64(dst[i])
				}
			}
			return frames
		}
		if !moved {
			now += 1000 // idle: advance time so timeouts would surface as a panic below
			if now > 10_000_000 {
				panic('isotp round stalled')
			}
		}
	}
	return 0
}

fn bench_isotp(size u32) {
	if size > isotp.max_payload {
		println('  ${size:5} B: beyond isotp.max_payload (${isotp.max_payload}) — bulk ring or block transfer territory')
		return
	}
	mut tx := isotp.Link{}
	mut rx := isotp.Link{}
	tx.init_defaults()
	rx.init_defaults()
	payload := []u8{len: int(size), init: u8(index)}
	mut dst := []u8{len: int(isotp.max_payload)}
	// one WARM round discarded, then ONE clock across all measured rounds — and it is
	// the PROCESS CPU clock: wall time would book preemption on a loaded host as
	// 'CPU cost' (codex #216). Per-round us truncation was the earlier /review catch.
	mut sink := u64(0)
	mut frames := isotp_round(mut tx, mut rx, payload, mut dst, mut &sink)
	rounds := 100
	t0 := C.cpu_ns()
	for _ in 0 .. rounds {
		frames = isotp_round(mut tx, mut rx, payload, mut dst, mut &sink)
	}
	cpu_us := f64(C.cpu_ns() - t0) / 1000.0 / f64(rounds)
	wire_ms := f64(frames) * us_per_frame / 1000.0
	println('  ${size:5} B: CPU ${cpu_us:7.2f} us/transfer   ${frames:3} CAN frames  -> ~${wire_ms:6.1f} ms @ classic 500 kbit/s (checksum ${sink & 0xff})')
}

fn main() {
	println('bulk_bench — the merged bulk ring (fork + MAP_SHARED) vs ISO-TP, per payload size')
	println('== ring throughput (max-rate producer, ${nbuf} buffers; ownership = the')
	println('   transport alone, filled = every byte written by the producer and read by')
	println('   the consumer — the honest bytes/s a real FB pair would see) ==')
	for s in sizes {
		bench_ring_throughput(s, false)
		bench_ring_throughput(s, true)
	}
	println('== ring latency (paced producer; size-INDEPENDENT by construction — the ring')
	println('   moves ownership, never bytes, so one measurement covers every size) ==')
	bench_ring_latency(256)
	println('== ISO-TP, same payload (host CPU + theoretical 500 kbit/s wire time) ==')
	for s in sizes {
		bench_isotp(s)
	}
	println('')
	println('reading (CLASSIC 500 kbit/s wire figures — the only path this stack')
	println('implements: comm/isotp segments into 8-byte PDUs regardless of bus): the ring')
	println('moves ownership in ~microseconds at any size; classic-CAN ISO-TP costs')
	println('milliseconds of BUS time per transfer. An FD ISO-TP path (larger frames)')
	println('would shrink wire time substantially — measure it when it exists, do not')
	println('extrapolate from these rows.')
}
