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
	if pid == 0 {
		// producer child: pump at max rate on its own clock for the parent's window
		// plus slack — no stop signal needed, the parent just stops taking
		sw := time.new_stopwatch()
		for sw.elapsed().milliseconds() < run_ms + 300 {
			idx := C.bulk_loan(b)
			if idx < 0 {
				continue
			}
			// touch first + last byte: the number measured is OWNERSHIP TRANSFER — the
			// whole point of the ring is that the payload is filled in place and never
			// copied, so a full memset here would just benchmark memset
			mut p := unsafe { &u8(C.bulk_buf(b, u32(idx))) }
			unsafe {
				p[0] = 1
				p[bufsz - 1] = 2
			}
			C.bulk_publish(b, u32(idx), bufsz)
		}
		C._exit(0)
	}
	mut got := u64(0)
	sw := time.new_stopwatch()
	for sw.elapsed().milliseconds() < run_ms {
		mut len := u32(0)
		idx := C.bulk_take(b, &len)
		if idx < 0 {
			continue
		}
		got++
		C.bulk_release(b, u32(idx))
	}
	el_us := f64(sw.elapsed().microseconds())
	mut status := 0
	C.waitpid(pid, &status, 0)
	mbps := f64(got) * f64(bufsz) / el_us // bytes/us == MB/s
	println('  ${bufsz:5} B: ${f64(got) * 1000.0 * 1000.0 / el_us:10.0f} payloads/s  ${mbps:8.1f} MB/s (ownership transfer only)')
	C.munmap(b, region_bytes)
}

// ---- 2. ring latency -------------------------------------------------------------

fn bench_ring_latency(bufsz u32) {
	b := region_new()
	C.bulk_init(b, nbuf, bufsz)
	pid := C.fork()
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
	for lats.len < lat_samples {
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
	p99 := f64(lats[lats.len * 99 / 100]) / 1000.0
	println('  ${bufsz:5} B: median ${median:7.1f} us   p99 ${p99:7.1f} us (publish -> take, paced)')
	C.munmap(b, region_bytes)
}

// ---- 3. ISO-TP, same payload -----------------------------------------------------

// One full segmentation round through a back-to-back Link pair on the host: sender
// frames -> receiver on_frame (receiver's FC frames -> sender). Returns CPU us and
// the CAN frame count the transfer needed.
fn isotp_round(mut tx isotp.Link, mut rx isotp.Link, payload []u8, mut dst []u8) (f64, int) {
	mut frames := 0
	sw := time.new_stopwatch()
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
			return f64(sw.elapsed().microseconds()), frames
		}
		if !moved {
			now += 1000 // idle: advance time so timeouts would surface as a panic below
			if now > 10_000_000 {
				panic('isotp round stalled')
			}
		}
	}
	return 0.0, 0
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
	// warm + measure over 100 rounds
	mut cpu_total := 0.0
	mut frames := 0
	for _ in 0 .. 100 {
		cpu, fr := isotp_round(mut tx, mut rx, payload, mut dst)
		cpu_total += cpu
		frames = fr
	}
	wire_ms := f64(frames) * us_per_frame / 1000.0
	println('  ${size:5} B: host CPU ${cpu_total / 100.0:7.1f} us/transfer   ${frames:3} CAN frames  -> ~${wire_ms:6.1f} ms on a 500 kbit/s bus')
}

fn main() {
	println('bulk_bench — the merged bulk ring (fork + MAP_SHARED) vs ISO-TP, per payload size')
	println('== ring throughput (max-rate producer, ${nbuf} buffers) ==')
	for s in sizes {
		bench_ring_throughput(s)
	}
	println('== ring latency (paced producer) ==')
	for s in sizes {
		bench_ring_latency(s)
	}
	println('== ISO-TP, same payload (host CPU + theoretical 500 kbit/s wire time) ==')
	for s in sizes {
		bench_isotp(s)
	}
	println('')
	println('reading: the ring moves ownership in ~microseconds at any size; ISO-TP costs')
	println('milliseconds of BUS time per transfer. The chip boundary is where payloads')
	println('stop being function-block state and start being paced protocol transfers.')
}
