module main

// @verifies REQ-BULK-001 REQ-BULK-002 REQ-BULK-003
// The portable bulk pool + descriptor ring (boards/common/bulk.h) on the host — the
// sim-first proof before any board work. Three layers:
//   1. the single-threaded contract: FIFO order, loan exhaustion (fallible + counted),
//      recycle after release;
//   2. a max-rate producer THREAD against a consuming test body: every consumed payload
//      is one complete published payload (word[i] == word[0] + i), order strictly
//      forward, counts add up — interleaving-independent assertions only;
//   3. the same across PROCESSES (fork + MAP_SHARED mmap) — the AMP model: two address
//      spaces sharing only the region, which is what the H755's two cores are to each
//      other. The plain-store discipline (XIOC_LD/ST/DMB seams) is what makes this the
//      same code path CI can test off-Arm (REQ-BULK-003).
//
// Honesty note (same as tools/xioc): x86's memory model is stronger than two Cortex
// cores over an AXI fabric — green here proves the LOGIC (ownership transfer, ordering,
// exhaustion), not the silicon. The H755 run rides the bench queue.

#flag -I @VMODROOT/boards/common
#include "bulk.h"
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

fn C.bulk_init(b voidptr, nbuf u32, bufsz u32)
fn C.bulk_valid(b voidptr) int
fn C.bulk_loan(b voidptr) int
fn C.bulk_overflows(b voidptr) u32
fn C.bulk_buf(b voidptr, idx u32) &u8
fn C.bulk_publish(b voidptr, idx u32, len u32)
fn C.bulk_ready(b voidptr) u32
fn C.bulk_take(b voidptr, len &u32) int
fn C.bulk_release(b voidptr, idx u32)

fn C.mmap(addr voidptr, len usize, prot int, flags int, fd int, off i64) voidptr
fn C.munmap(addr voidptr, len usize) int
fn C.fork() int
fn C.waitpid(pid int, status &int, options int) int
fn C._exit(code int)

const nbuf = u32(4)
const bufsz = u32(256) // 64 u32 words per payload
const words = int(bufsz / 4)
const region_bytes = usize(8192) // > BULK_BYTES(4, 256) = 96 + 32 + 1024

__global (
	g_region [8256]u8 // 8192 + 63 slack: region() rounds the base to the 32 B alignment
	// bulk_t requires (a byte arena guarantees none — codex #213)
)

fn region() voidptr {
	base := (usize(voidptr(&g_region[0])) + 31) & ~usize(31)
	return voidptr(base)
}

fn fill(b voidptr, idx u32, seq u32) {
	mut p := unsafe { &u32(C.bulk_buf(b, idx)) }
	for i in 0 .. words {
		unsafe {
			p[i] = seq + u32(i) // the consistency invariant: word[i] - word[0] == i
		}
	}
}

// check returns the payload's base seq after asserting it is one COMPLETE payload.
fn check(b voidptr, idx u32, len u32) u32 {
	assert len == bufsz
	p := unsafe { &u32(C.bulk_buf(b, idx)) }
	base := unsafe { p[0] }
	for i in 1 .. words {
		v := unsafe { p[i] }
		assert v - base == u32(i), 'torn payload: word ${i} of base ${base} reads ${v}'
	}
	return base
}

fn test_fifo_exhaustion_and_recycle() {
	b := region()
	C.bulk_init(b, nbuf, bufsz)
	assert C.bulk_valid(b) == 1
	assert C.bulk_overflows(b) == 0

	// loan the WHOLE pool, publish in order
	mut loaned := []int{}
	for s in 0 .. int(nbuf) {
		idx := C.bulk_loan(b)
		assert idx >= 0
		fill(b, u32(idx), u32(1000 + s * 100))
		loaned << idx
	}
	// pool exhausted: loan fails and every failure is COUNTED (REQ-BULK-002 is the
	// counter, not just the -1 — a green test must notice a broken increment)
	assert C.bulk_loan(b) == -1
	assert C.bulk_loan(b) == -1
	assert C.bulk_overflows(b) == 2
	for s, idx in loaned {
		C.bulk_publish(b, u32(idx), bufsz)
		assert C.bulk_ready(b) == u32(s + 1)
	}
	// consume: publish order, complete payloads
	for s in 0 .. int(nbuf) {
		mut len := u32(0)
		idx := C.bulk_take(b, &len)
		assert idx >= 0
		assert check(b, u32(idx), len) == u32(1000 + s * 100)
		C.bulk_release(b, u32(idx))
	}
	mut l := u32(0)
	assert C.bulk_take(b, &l) == -1
	// released buffers loan again — the pool recycles. The loaned buffer stays the
	// producer's (publish-or-keep; a producer never calls release — its cursor is
	// consumer-owned, codex #213), so the pool now has nbuf-1 loanable buffers.
	idx2 := C.bulk_loan(b)
	assert idx2 >= 0
	fill(b, u32(idx2), 9000)
	C.bulk_publish(b, u32(idx2), bufsz)
	idx3 := C.bulk_take(b, &l)
	assert idx3 == idx2 && check(b, u32(idx3), l) == 9000
	C.bulk_release(b, u32(idx3))
}

const t_payloads = u32(50_000)

fn producer(b voidptr) {
	mut seq := u32(1)
	for seq <= t_payloads {
		idx := C.bulk_loan(b)
		if idx < 0 {
			continue // pool full: the consumer is behind — spin (test wants exactly N through)
		}
		fill(b, u32(idx), seq)
		C.bulk_publish(b, u32(idx), bufsz)
		seq++
	}
}

fn test_cross_thread_every_payload_complete_and_ordered() {
	b := region()
	C.bulk_init(b, nbuf, bufsz)
	t := spawn producer(b)

	mut got := u32(0)
	mut last := u32(0)
	for got < t_payloads {
		mut len := u32(0)
		idx := C.bulk_take(b, &len)
		if idx < 0 {
			continue
		}
		base := check(b, u32(idx), len)
		assert base > last, 'order went backwards: ${base} after ${last}'
		last = base
		got++
		C.bulk_release(b, u32(idx))
	}
	t.wait()
	// every payload arrived exactly once, in order, and the pool is whole again
	assert last == t_payloads
	mut len := u32(0)
	assert C.bulk_take(b, &len) == -1
	for _ in 0 .. int(nbuf) {
		assert C.bulk_loan(b) >= 0
	}
}

const mp_payloads = u32(20_000)

fn test_cross_process_fork_mmap() {
	// the AMP shape: MAP_SHARED region created BEFORE fork — afterwards the two sides
	// share nothing else (REQ-BULK-001 across real address spaces)
	region := C.mmap(unsafe { nil }, region_bytes, 0x1 | 0x2, 0x01 | 0x20, -1, 0)
	// PROT_READ|PROT_WRITE = 0x3, MAP_SHARED|MAP_ANONYMOUS = 0x21 (linux)
	assert region != unsafe { voidptr(-1) }
	C.bulk_init(region, nbuf, bufsz)

	pid := C.fork()
	if pid == 0 {
		// child: the producer core
		mut seq := u32(1)
		for seq <= mp_payloads {
			idx := C.bulk_loan(region)
			if idx < 0 {
				continue
			}
			fill(region, u32(idx), seq)
			C.bulk_publish(region, u32(idx), bufsz)
			seq++
		}
		C._exit(0)
	}
	assert pid > 0

	mut got := u32(0)
	mut last := u32(0)
	for got < mp_payloads {
		mut len := u32(0)
		idx := C.bulk_take(region, &len)
		if idx < 0 {
			continue
		}
		base := check(region, u32(idx), len)
		assert base > last, 'cross-process order went backwards: ${base} after ${last}'
		last = base
		got++
		C.bulk_release(region, u32(idx))
	}
	assert last == mp_payloads

	mut status := 0
	C.waitpid(pid, &status, 0)
	C.munmap(region, region_bytes)
}
