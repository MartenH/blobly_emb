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
#include "bulk.h"
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

fn bench_ring_throughput(bufsz u32) {
	b := region_new()
	C.bulk_init(b, nbuf, bufsz)
	pid := C.fork()
	if pid < 0 {
		panic('fork failed')
	}
	if pid == 0 {
		// producer child: pump at max rate on its own clock for the parent's window
		// plus slack — no stop signal needed, the parent just stops taking. Deadline
		// checked every 1024 payloads: a clock read per payload would sit inside the
		// measured window and bias small sizes.
		sw := time.new_stopwatch()
		for {
			for _ in 0 .. 1024 {
				idx := C.bulk_loan(b)
				if idx < 0 {
					continue
				}
				// touch first + last byte: the number measured is OWNERSHIP TRANSFER —
				// the payload is filled in place and never copied by the transport, so
				// a full memset here would just benchmark memset
				mut p := unsafe { &u8(C.bulk_buf(b, u32(idx))) }
				unsafe {
					p[0] = 1
					p[bufsz - 1] = 2
				}
				C.bulk_publish(b, u32(idx), bufsz)
			}
			if sw.elapsed().milliseconds() >= run_ms + 300 {
				break
			}
		}
		C._exit(0)
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
	sw := time.new_stopwatch()
	for {
		for _ in 0 .. 1024 {
			idx := C.bulk_take(b, &len)
			if idx < 0 {
				continue
			}
			got++
			C.bulk_release(b, u32(idx))
		}
		if sw.elapsed().milliseconds() >= run_ms {
			break
		}
	}
	el_us := f64(sw.elapsed().microseconds())
	mut status := 0
	C.waitpid(pid, &status, 0)
	// producer-owned counter, read only after the producer exited: the saturation
	// number REQ-BULK-002 makes observable
	ovf := C.bulk_overflows(b)
	println('  ${bufsz:5} B: ${f64(got) * 1000.0 * 1000.0 / el_us / 1000.0 / 1000.0:6.2f} M transfers/s (ownership only — the payload is filled in place, no bytes move through the ring; ${ovf} failed loans at saturation)')
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
		// PACED producer (one payload per ~200 us): the pool never saturates, so the
		// measured delay is the transport's, not queueing. The stamp is the child's
		// monotonic clock; parent and child share the boot clock base on Linux.
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
	lats.sort()
	median := f64(lats[lats.len / 2]) / 1000.0
	p99 := f64(lats[(lats.len - 1) * 99 / 100]) / 1000.0
	println('  median ${median:7.1f} us   p99 ${p99:7.1f} us (publish -> take, paced; unpinned p99 is scheduler noise)')
	C.munmap(b, region_bytes)
}

// ---- 3. ISO-TP, same payload -----------------------------------------------------

// One full segmentation round through a back-to-back Link pair on the host: sender
// frames -> receiver on_frame (receiver's FC frames -> sender). Returns CPU us and
// the CAN frame count the transfer needed.
fn isotp_round(mut tx isotp.Link, mut rx isotp.Link, payload []u8, mut dst []u8) int {
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
	// one WARM round discarded, then ONE stopwatch across all measured rounds: a
	// per-round Duration.microseconds() truncates sub-us rounds to 0 and the average
	// becomes quantization noise (caught by /review)
	mut frames := isotp_round(mut tx, mut rx, payload, mut dst)
	rounds := 100
	sw := time.new_stopwatch()
	for _ in 0 .. rounds {
		frames = isotp_round(mut tx, mut rx, payload, mut dst)
	}
	cpu_us := f64(sw.elapsed().nanoseconds()) / 1000.0 / f64(rounds)
	wire_ms := f64(frames) * us_per_frame / 1000.0
	println('  ${size:5} B: host CPU ${cpu_us:7.2f} us/transfer   ${frames:3} CAN frames  -> ~${wire_ms:6.1f} ms @ classic 500 kbit/s')
}

fn main() {
	println('bulk_bench — the merged bulk ring (fork + MAP_SHARED) vs ISO-TP, per payload size')
	println('== ring throughput (max-rate producer, ${nbuf} buffers) ==')
	for s in sizes {
		bench_ring_throughput(s)
	}
	println('== ring latency (paced producer; size-INDEPENDENT by construction — the ring')
	println('   moves ownership, never bytes, so one measurement covers every size) ==')
	bench_ring_latency(256)
	println('== ISO-TP, same payload (host CPU + theoretical 500 kbit/s wire time) ==')
	for s in sizes {
		bench_isotp(s)
	}
	println('')
	println('reading (CLASSIC 500 kbit/s wire figures): the ring moves ownership in')
	println('~microseconds at any size; classic-CAN ISO-TP costs milliseconds of BUS time')
	println('per transfer. CAN-FD shrinks the wire time ~20-40x (64 B frames, faster data')
	println('phase) — size the off-chip boundary against the bus actually configured.')
}
